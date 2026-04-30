import {
	BedrockRuntimeClient,
	type ConverseStreamOutput,
	InternalServerException,
	ModelStreamErrorException,
	ServiceUnavailableException,
	ThrottlingException,
	ValidationException,
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
import { streamSimple } from "../../packages/ai/src/stream.js";
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
	"packages/ai/src/stream.ts:43-48",
	"packages/ai/src/providers/amazon-bedrock.ts:598-957",
	"zig/src/ai/providers/bedrock.zig:169-754",
	"zig/src/ai/providers/bedrock.zig:781-1427",
] as const;

const allowedScenarioIds = [
	"bedrock-stream-no-explicit-inference",
	"bedrock-stream-basic-text",
	"bedrock-stream-metadata-response",
	"bedrock-stream-thinking-signature",
	"bedrock-stream-tool-fragmented-json",
	"bedrock-stream-interleaved-block-indexes",
	"bedrock-stream-usage-cache-total-fallback",
	"bedrock-stream-stop-sequence",
	"bedrock-stream-max-tokens",
	"bedrock-stream-context-window-exceeded",
	"bedrock-stream-unknown-stop-reason",
	"bedrock-stream-non-assistant-message-start",
	"bedrock-stream-validation-exception",
	"bedrock-stream-throttling-exception",
	"bedrock-stream-send-service-unavailable-exception",
	"bedrock-stream-partial-model-exception",
	"bedrock-stream-pre-abort",
	"bedrock-stream-mid-abort",
	"bedrock-binary-eventstream-exception",
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
	"bedrock-reasoning-fixed-default-minimal",
	"bedrock-reasoning-fixed-default-low",
	"bedrock-reasoning-fixed-default-medium",
	"bedrock-reasoning-fixed-default-high",
	"bedrock-reasoning-fixed-default-xhigh",
	"bedrock-reasoning-fixed-custom-low",
	"bedrock-reasoning-fixed-custom-high",
	"bedrock-reasoning-fixed-custom-xhigh",
	"bedrock-reasoning-adaptive-opus46-xhigh",
	"bedrock-reasoning-adaptive-opus47-xhigh",
	"bedrock-reasoning-adaptive-sonnet46-xhigh",
	"bedrock-reasoning-adaptive-minimal-effort",
	"bedrock-reasoning-adaptive-display-omitted",
	"bedrock-reasoning-govcloud-fixed-model",
	"bedrock-reasoning-govcloud-adaptive-region",
	"bedrock-reasoning-govcloud-adaptive-aws-region",
	"bedrock-reasoning-govcloud-adaptive-aws-default-region",
	"bedrock-reasoning-govcloud-adaptive-arn",
	"bedrock-reasoning-interleaved-default",
	"bedrock-reasoning-interleaved-true",
	"bedrock-app-profile-adaptive-by-name",
	"bedrock-app-profile-fixed-by-name",
	"bedrock-app-profile-nonclaude-by-name",
	"bedrock-simple-fixed-reasoning-adjust",
	"bedrock-public-simple-fixed-reasoning-adjust",
	"bedrock-simple-fixed-reasoning-custom-cap",
	"bedrock-simple-no-reasoning-no-adjust",
	"bedrock-simple-adaptive-no-adjust",
	"bedrock-simple-nonclaude-no-adjust",
	"bedrock-transform-replay-edge-cases",
	"bedrock-simple-explicit-tokens",
	"bedrock-binary-eventstream-tool-use",
	"bedrock-auth-path-encoding",
	"bedrock-auth-standard-endpoint-eu",
	"bedrock-auth-standard-endpoint-fips",
	"bedrock-auth-standard-endpoint-china",
	"bedrock-auth-region-precedence-options",
	"bedrock-auth-region-precedence-env",
	"bedrock-auth-region-precedence-default-env",
	"bedrock-auth-aws-profile-env",
	"bedrock-auth-options-profile",
	"bedrock-auth-custom-endpoint-region",
	"bedrock-auth-bearer-option",
	"bedrock-auth-bearer-env",
	"bedrock-auth-skip-auth-proxy",
	"bedrock-auth-sigv4-session",
	"bedrock-auth-missing-credentials",
] as const;

const allowedModelIds = [
	"anthropic.claude-3-7-sonnet-20250219-v1:0",
	"anthropic.claude-3-5-haiku-20241022-v1:0",
	"amazon.nova-pro-v1:0",
	"us.anthropic.claude-sonnet-4-5-20250929-v1:0",
	"us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0",
	"global.anthropic.claude-opus-4-6-v1",
	"global.anthropic.claude-opus-4-7-v1",
	"global.anthropic.claude-sonnet-4-6-v1",
	"arn:aws-us-gov:bedrock:us-gov-west-1:123456789012:inference-profile/global.anthropic.claude-opus-4-7-v1",
	"arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/fixture-profile",
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

const fixtureTimestamp = {
	amzDate: "20250115T120000Z",
	dateStamp: "20250115",
} as const;

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
	maxTokens?: number;
	cost?: { input: number; output: number; cacheRead: number; cacheWrite: number };
}

interface SerializableOptions {
	cacheRetention?: "none" | "short" | "long";
	region?: string;
	profile?: string;
	bearerToken?: string;
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
	requestSurface?: "capture";
	sendException?: "ServiceUnavailableException";
	abort?: "pre" | "mid";
}

type FixtureEnvKey =
	| "AWS_ACCESS_KEY_ID"
	| "AWS_SECRET_ACCESS_KEY"
	| "AWS_SESSION_TOKEN"
	| "AWS_PROFILE"
	| "AWS_BEARER_TOKEN_BEDROCK"
	| "AWS_REGION"
	| "AWS_DEFAULT_REGION"
	| "AWS_BEDROCK_SKIP_AUTH";

type FixtureEnv = Partial<Record<FixtureEnvKey, string>>;

interface DeclarativeContext {
	systemPrompt?: string;
	messages: DeclarativeMessage[];
	tools?: Context["tools"];
}

interface ScenarioInput {
	mode: "streamBedrock" | "streamSimpleBedrock" | "streamSimple";
	model: FixtureModelInput;
	context: DeclarativeContext;
	options: SerializableOptions;
	env?: FixtureEnv;
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
	| {
			metadata: {
				usage: {
					inputTokens?: number;
					outputTokens?: number;
					totalTokens?: number;
					cacheReadInputTokens?: number;
					cacheWriteInputTokens?: number;
				};
			};
	  }
	| { internalServerException: { message: string } }
	| { modelStreamErrorException: { message: string } }
	| { validationException: { message: string } }
	| { throttlingException: { message: string } }
	| { serviceUnavailableException: { message: string } };

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
			requestSurface?: unknown;
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

const sonnet45Model: FixtureModelInput = {
	...baseModel,
	id: "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
	name: "Claude Sonnet 4.5 Bedrock Fixture",
};

const govCloudSonnet45Model: FixtureModelInput = {
	...sonnet45Model,
	id: "us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0",
	name: "Claude Sonnet 4.5 GovCloud Fixture",
};

const opus46Model: FixtureModelInput = {
	...baseModel,
	id: "global.anthropic.claude-opus-4-6-v1",
	name: "Claude Opus 4.6 Global Fixture",
};

const opus47Model: FixtureModelInput = {
	...baseModel,
	id: "global.anthropic.claude-opus-4-7-v1",
	name: "Claude Opus 4.7 Global Fixture",
};

const sonnet46Model: FixtureModelInput = {
	...baseModel,
	id: "global.anthropic.claude-sonnet-4-6-v1",
	name: "Claude Sonnet 4.6 Global Fixture",
};

const govCloudAdaptiveArnModel: FixtureModelInput = {
	...baseModel,
	id: "arn:aws-us-gov:bedrock:us-gov-west-1:123456789012:inference-profile/global.anthropic.claude-opus-4-7-v1",
	name: "Claude Opus 4.7 GovCloud ARN Fixture",
};

const appProfileAdaptiveModel: FixtureModelInput = {
	...baseModel,
	id: "arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/fixture-profile",
	name: "Claude Opus 4.6 Application Profile Fixture",
};

const appProfileFixedModel: FixtureModelInput = {
	...appProfileAdaptiveModel,
	name: "Claude Sonnet 4.5 Application Profile Fixture",
};

const appProfileNonClaudeModel: FixtureModelInput = {
	...appProfileAdaptiveModel,
	name: "Nova Pro Application Profile Fixture",
};

const cappedClaudeModel: FixtureModelInput = {
	...baseModel,
	name: "Claude 3.7 Sonnet Capped Fixture",
	maxTokens: 10_000,
};

const fipsEndpointModel: FixtureModelInput = {
	...baseModel,
	baseUrl: "https://bedrock-runtime-fips.us-gov-west-1.amazonaws.com",
};

const chinaEndpointModel: FixtureModelInput = {
	...baseModel,
	baseUrl: "https://bedrock-runtime.cn-north-1.amazonaws.com.cn",
};

const customEndpointModel: FixtureModelInput = {
	...baseModel,
	baseUrl: "https://bedrock-proxy.fixture.example.com/custom/",
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

const thinkingEvents: ConverseStreamFixtureEvent[] = [
	{ messageStart: { role: "assistant" } },
	{ contentBlockDelta: { contentBlockIndex: 0, delta: { reasoningContent: { text: "First thought. ", signature: "sig-a" } } } },
	{ contentBlockDelta: { contentBlockIndex: 0, delta: { reasoningContent: { text: "Second thought.", signature: "sig-b" } } } },
	{ contentBlockStop: { contentBlockIndex: 0 } },
	{ messageStop: { stopReason: "end_turn" } },
	{ metadata: { usage: { inputTokens: 9, outputTokens: 4, totalTokens: 13 } } },
];

const interleavedEvents: ConverseStreamFixtureEvent[] = [
	{ messageStart: { role: "assistant" } },
	{ contentBlockDelta: { contentBlockIndex: 2, delta: { text: "Later text." } } },
	{ contentBlockDelta: { contentBlockIndex: 0, delta: { reasoningContent: { text: "Earlier thought.", signature: "sig-interleaved" } } } },
	{
		contentBlockStart: {
			contentBlockIndex: 1,
			start: { toolUse: { toolUseId: "tool-interleaved", name: "get_weather" } },
		},
	},
	{ contentBlockDelta: { contentBlockIndex: 1, delta: { toolUse: { input: "{\"city\":\"Rome\"}" } } } },
	{ contentBlockStop: { contentBlockIndex: 0 } },
	{ contentBlockStop: { contentBlockIndex: 2 } },
	{ contentBlockStop: { contentBlockIndex: 1 } },
	{ messageStop: { stopReason: "tool_use" } },
	{ metadata: { usage: { inputTokens: 17, outputTokens: 8, totalTokens: 25 } } },
];

const usageCacheFallbackEvents: ConverseStreamFixtureEvent[] = [
	{ messageStart: { role: "assistant" } },
	{ contentBlockDelta: { contentBlockIndex: 0, delta: { text: "Usage fallback." } } },
	{ contentBlockStop: { contentBlockIndex: 0 } },
	{ messageStop: { stopReason: "end_turn" } },
	{ metadata: { usage: { inputTokens: 11, outputTokens: 6, cacheReadInputTokens: 3, cacheWriteInputTokens: 2 } } },
];

function stopReasonEvents(stopReason: string): ConverseStreamFixtureEvent[] {
	return [
		{ messageStart: { role: "assistant" } },
		{ contentBlockDelta: { contentBlockIndex: 0, delta: { text: `Stop reason ${stopReason}.` } } },
		{ contentBlockStop: { contentBlockIndex: 0 } },
		{ messageStop: { stopReason } },
		{ metadata: { usage: { inputTokens: 3, outputTokens: 2, totalTokens: 5 } } },
	];
}

const partialModelExceptionEvents: ConverseStreamFixtureEvent[] = [
	{ messageStart: { role: "assistant" } },
	{ contentBlockDelta: { contentBlockIndex: 0, delta: { text: "Partial before model error." } } },
	{ modelStreamErrorException: { message: "stream failed deterministically" } },
];

const midAbortEvents: ConverseStreamFixtureEvent[] = [
	{ messageStart: { role: "assistant" } },
	{ contentBlockDelta: { contentBlockIndex: 0, delta: { text: "Partial before abort." } } },
];

function reasoningScenario(
	id: ScenarioId,
	title: string,
	model: FixtureModelInput,
	options: SerializableOptions,
	mode: ScenarioInput["mode"] = "streamBedrock",
	env?: FixtureEnv,
): Scenario {
	return {
		id,
		title,
		input: {
			mode,
			model,
			context: baseContext,
			options: { cacheRetention: "none", ...options },
			...(env ? { env } : {}),
			localStream: { format: "json-lines", events: textEvents },
		},
	};
}

function authScenario(
	id: ScenarioId,
	title: string,
	model: FixtureModelInput,
	options: SerializableOptions = {},
	env: FixtureEnv = {},
): Scenario {
	return {
		id,
		title,
		input: {
			mode: "streamBedrock",
			model,
			context: { messages: [{ role: "user", content: `Auth surface fixture ${id}.` }] },
			options: { cacheRetention: "none", maxTokens: 32, requestSurface: "capture", ...options },
			env,
			localStream: { format: "json-lines", events: textEvents },
		},
	};
}

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
		id: "bedrock-stream-thinking-signature",
		title: "Bedrock streamBedrock preserves thinking deltas and signatures",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: { format: "json-lines", events: thinkingEvents },
		},
	},
	{
		id: "bedrock-stream-tool-fragmented-json",
		title: "Bedrock streamBedrock finalizes fragmented tool JSON",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: { ...baseContext, tools: [fixtureTool] },
			options: { cacheRetention: "none", maxTokens: 80 },
			localStream: { format: "json-lines", events: toolUseEvents },
		},
	},
	{
		id: "bedrock-stream-interleaved-block-indexes",
		title: "Bedrock streamBedrock preserves interleaved Bedrock content block order",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: { ...baseContext, tools: [fixtureTool] },
			options: { cacheRetention: "none", maxTokens: 80 },
			localStream: { format: "json-lines", events: interleavedEvents },
		},
	},
	{
		id: "bedrock-stream-usage-cache-total-fallback",
		title: "Bedrock streamBedrock maps cache usage and falls back totalTokens to input plus output",
		input: {
			mode: "streamBedrock",
			model: { ...baseModel, cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 } },
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: { format: "json-lines", events: usageCacheFallbackEvents },
		},
	},
	{
		id: "bedrock-stream-stop-sequence",
		title: "Bedrock streamBedrock maps stop_sequence to stop",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: { format: "json-lines", events: stopReasonEvents("stop_sequence") },
		},
	},
	{
		id: "bedrock-stream-max-tokens",
		title: "Bedrock streamBedrock maps max_tokens to length",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: { format: "json-lines", events: stopReasonEvents("max_tokens") },
		},
	},
	{
		id: "bedrock-stream-context-window-exceeded",
		title: "Bedrock streamBedrock maps model_context_window_exceeded to length",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: { format: "json-lines", events: stopReasonEvents("model_context_window_exceeded") },
		},
	},
	{
		id: "bedrock-stream-unknown-stop-reason",
		title: "Bedrock streamBedrock terminates unknown stop reasons through the error contract",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: { format: "json-lines", events: stopReasonEvents("unexpected_fixture_reason") },
		},
	},
	{
		id: "bedrock-stream-non-assistant-message-start",
		title: "Bedrock streamBedrock returns a stream error for non-assistant messageStart",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: { format: "json-lines", events: [{ messageStart: { role: "user" } }] },
		},
	},
	{
		id: "bedrock-stream-validation-exception",
		title: "Bedrock streamBedrock formats validation stream exceptions",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: { format: "json-lines", events: [{ validationException: { message: "invalid fixture stream" } }] },
		},
	},
	{
		id: "bedrock-stream-throttling-exception",
		title: "Bedrock streamBedrock formats throttling stream exceptions",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: { format: "json-lines", events: [{ throttlingException: { message: "slow down fixture" } }] },
		},
	},
	{
		id: "bedrock-stream-send-service-unavailable-exception",
		title: "Bedrock streamBedrock formats service unavailable send exceptions",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64, sendException: "ServiceUnavailableException" },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-stream-partial-model-exception",
		title: "Bedrock streamBedrock preserves partial content when model stream exceptions occur",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: { format: "json-lines", events: partialModelExceptionEvents },
		},
	},
	{
		id: "bedrock-stream-pre-abort",
		title: "Bedrock streamBedrock finalizes pre-aborted requests through the aborted error contract",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64, abort: "pre" },
			localStream: { format: "json-lines", events: [] },
		},
	},
	{
		id: "bedrock-stream-mid-abort",
		title: "Bedrock streamBedrock preserves partial content for mid-stream aborts",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64, abort: "mid" },
			localStream: { format: "json-lines", events: midAbortEvents },
		},
	},
	{
		id: "bedrock-binary-eventstream-exception",
		title: "Bedrock binary AWS EventStream fixture covers exception frames",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: {
				format: "aws-eventstream",
				events: [
					{ messageStart: { role: "assistant" } },
					{ contentBlockDelta: { contentBlockIndex: 0, delta: { text: "Binary partial." } } },
					{ internalServerException: { message: "binary internal failure" } },
				],
			},
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
	reasoningScenario(
		"bedrock-reasoning-fixed-default-minimal",
		"Bedrock fixed Claude minimal reasoning uses the default 1024 token budget",
		baseModel,
		{ maxTokens: 20_000, reasoning: "minimal" },
	),
	reasoningScenario(
		"bedrock-reasoning-fixed-default-low",
		"Bedrock fixed Claude low reasoning uses the default 2048 token budget",
		baseModel,
		{ maxTokens: 20_000, reasoning: "low" },
	),
	reasoningScenario(
		"bedrock-reasoning-fixed-default-medium",
		"Bedrock fixed Claude medium reasoning uses the default 8192 token budget",
		baseModel,
		{ maxTokens: 20_000, reasoning: "medium" },
	),
	reasoningScenario(
		"bedrock-reasoning-fixed-default-high",
		"Bedrock fixed Claude high reasoning uses the default 16384 token budget",
		baseModel,
		{ maxTokens: 20_000, reasoning: "high" },
	),
	reasoningScenario(
		"bedrock-reasoning-fixed-default-xhigh",
		"Bedrock fixed Claude xhigh reasoning clamps to the high default token budget",
		baseModel,
		{ maxTokens: 20_000, reasoning: "xhigh" },
	),
	reasoningScenario(
		"bedrock-reasoning-fixed-custom-low",
		"Bedrock fixed Claude low reasoning honors a custom token budget",
		baseModel,
		{ maxTokens: 20_000, reasoning: "low", thinkingBudgets: { low: 3072 } },
	),
	reasoningScenario(
		"bedrock-reasoning-fixed-custom-high",
		"Bedrock fixed Claude high reasoning honors a custom token budget and explicit interleaved true",
		baseModel,
		{ maxTokens: 20_000, reasoning: "high", thinkingBudgets: { high: 12_000 }, interleavedThinking: true },
	),
	reasoningScenario(
		"bedrock-reasoning-fixed-custom-xhigh",
		"Bedrock fixed Claude xhigh reasoning uses the custom high token budget",
		baseModel,
		{ maxTokens: 20_000, reasoning: "xhigh", thinkingBudgets: { high: 14_000 } },
	),
	reasoningScenario(
		"bedrock-reasoning-adaptive-opus46-xhigh",
		"Bedrock adaptive Claude Opus 4.6 maps xhigh reasoning to max effort",
		opus46Model,
		{ maxTokens: 128, reasoning: "xhigh" },
	),
	reasoningScenario(
		"bedrock-reasoning-adaptive-opus47-xhigh",
		"Bedrock adaptive Claude Opus 4.7 maps xhigh reasoning to xhigh effort",
		opus47Model,
		{ maxTokens: 128, reasoning: "xhigh" },
	),
	reasoningScenario(
		"bedrock-reasoning-adaptive-sonnet46-xhigh",
		"Bedrock adaptive Claude Sonnet 4.6 maps xhigh reasoning to high effort",
		sonnet46Model,
		{ maxTokens: 128, reasoning: "xhigh" },
	),
	reasoningScenario(
		"bedrock-reasoning-adaptive-minimal-effort",
		"Bedrock adaptive Claude minimal reasoning maps to low effort",
		opus47Model,
		{ maxTokens: 128, reasoning: "minimal" },
	),
	reasoningScenario(
		"bedrock-reasoning-adaptive-display-omitted",
		"Bedrock adaptive Claude forwards explicit omitted thinking display outside GovCloud",
		opus47Model,
		{ maxTokens: 128, reasoning: "high", thinkingDisplay: "omitted" },
	),
	reasoningScenario(
		"bedrock-reasoning-govcloud-fixed-model",
		"Bedrock GovCloud fixed Claude model ids omit thinking display",
		govCloudSonnet45Model,
		{ maxTokens: 20_000, reasoning: "high", thinkingDisplay: "omitted" },
	),
	reasoningScenario(
		"bedrock-reasoning-govcloud-adaptive-region",
		"Bedrock GovCloud regions omit thinking display for adaptive Claude",
		opus47Model,
		{ region: "us-gov-west-1", maxTokens: 128, reasoning: "high", thinkingDisplay: "omitted" },
	),
	reasoningScenario(
		"bedrock-reasoning-govcloud-adaptive-aws-region",
		"Bedrock AWS_REGION GovCloud config omits thinking display for adaptive Claude",
		opus47Model,
		{ maxTokens: 128, reasoning: "high", thinkingDisplay: "omitted" },
		"streamBedrock",
		{ AWS_REGION: "us-gov-west-1" },
	),
	reasoningScenario(
		"bedrock-reasoning-govcloud-adaptive-aws-default-region",
		"Bedrock AWS_DEFAULT_REGION GovCloud config omits thinking display for adaptive Claude",
		opus47Model,
		{ maxTokens: 128, reasoning: "high", thinkingDisplay: "omitted" },
		"streamBedrock",
		{ AWS_DEFAULT_REGION: "us-gov-west-1" },
	),
	reasoningScenario(
		"bedrock-reasoning-govcloud-adaptive-arn",
		"Bedrock GovCloud ARNs omit thinking display for adaptive Claude",
		govCloudAdaptiveArnModel,
		{ maxTokens: 128, reasoning: "high" },
	),
	reasoningScenario(
		"bedrock-reasoning-interleaved-default",
		"Bedrock fixed Claude reasoning emits interleaved thinking beta by default",
		baseModel,
		{ maxTokens: 20_000, reasoning: "high" },
	),
	reasoningScenario(
		"bedrock-reasoning-interleaved-true",
		"Bedrock fixed Claude reasoning emits interleaved thinking beta when explicitly true",
		baseModel,
		{ maxTokens: 20_000, reasoning: "medium", interleavedThinking: true },
	),
	reasoningScenario(
		"bedrock-app-profile-adaptive-by-name",
		"Bedrock application inference profiles use model.name for adaptive Claude reasoning",
		appProfileAdaptiveModel,
		{ maxTokens: 128, reasoning: "xhigh" },
	),
	reasoningScenario(
		"bedrock-app-profile-fixed-by-name",
		"Bedrock application inference profiles use model.name for fixed-budget Claude reasoning",
		appProfileFixedModel,
		{ maxTokens: 20_000, reasoning: "high" },
	),
	reasoningScenario(
		"bedrock-app-profile-nonclaude-by-name",
		"Bedrock application inference profiles omit reasoning fields when model.name is not Claude",
		appProfileNonClaudeModel,
		{ maxTokens: 128, reasoning: "high" },
	),
	reasoningScenario(
		"bedrock-simple-fixed-reasoning-adjust",
		"Bedrock streamSimple fixed Claude reasoning adjusts max tokens and thinking budget within the model cap",
		baseModel,
		{ maxTokens: 128, reasoning: "high" },
		"streamSimpleBedrock",
	),
	reasoningScenario(
		"bedrock-public-simple-fixed-reasoning-adjust",
		"Bedrock public streamSimple fixed Claude reasoning applies provider-specific max token adjustment",
		baseModel,
		{ maxTokens: 128, reasoning: "high" },
		"streamSimple",
	),
	reasoningScenario(
		"bedrock-simple-fixed-reasoning-custom-cap",
		"Bedrock streamSimple fixed Claude reasoning preserves custom budget when the capped max tokens allow output",
		cappedClaudeModel,
		{ maxTokens: 7000, reasoning: "high", thinkingBudgets: { high: 5000 } },
		"streamSimpleBedrock",
	),
	reasoningScenario(
		"bedrock-simple-no-reasoning-no-adjust",
		"Bedrock streamSimple without reasoning keeps explicit max tokens and omits reasoning fields",
		baseModel,
		{ maxTokens: 128 },
		"streamSimpleBedrock",
	),
	reasoningScenario(
		"bedrock-simple-adaptive-no-adjust",
		"Bedrock streamSimple adaptive Claude reasoning does not apply fixed-budget token reserve",
		opus47Model,
		{ maxTokens: 128, reasoning: "xhigh" },
		"streamSimpleBedrock",
	),
	reasoningScenario(
		"bedrock-simple-nonclaude-no-adjust",
		"Bedrock streamSimple non-Claude reasoning does not apply fixed-budget token reserve",
		novaModel,
		{ maxTokens: 128, reasoning: "high" },
		"streamSimpleBedrock",
	),
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
	authScenario(
		"bedrock-auth-path-encoding",
		"Bedrock request URL percent-encodes ARN model ids as a single path segment",
		govCloudAdaptiveArnModel,
		{},
		{ AWS_BEDROCK_SKIP_AUTH: "1" },
	),
	authScenario(
		"bedrock-auth-standard-endpoint-eu",
		"Bedrock standard EU runtime endpoint derives eu-central-1 signing region",
		{ ...baseModel, baseUrl: "https://bedrock-runtime.eu-central-1.amazonaws.com" },
		{},
		{ AWS_BEDROCK_SKIP_AUTH: "1" },
	),
	authScenario(
		"bedrock-auth-standard-endpoint-fips",
		"Bedrock FIPS runtime endpoint derives its signing region",
		fipsEndpointModel,
		{},
		{ AWS_BEDROCK_SKIP_AUTH: "1" },
	),
	authScenario(
		"bedrock-auth-standard-endpoint-china",
		"Bedrock China runtime endpoint derives cn-north-1 signing region",
		chinaEndpointModel,
		{},
		{ AWS_BEDROCK_SKIP_AUTH: "1" },
	),
	authScenario(
		"bedrock-auth-region-precedence-options",
		"Bedrock options.region takes precedence over environment and endpoint regions",
		{ ...baseModel, baseUrl: "https://bedrock-runtime.eu-central-1.amazonaws.com" },
		{ region: "ap-southeast-2" },
		{ AWS_REGION: "us-west-2", AWS_DEFAULT_REGION: "us-east-2", AWS_BEDROCK_SKIP_AUTH: "1" },
	),
	authScenario(
		"bedrock-auth-region-precedence-env",
		"Bedrock AWS_REGION takes precedence over AWS_DEFAULT_REGION and endpoint regions",
		{ ...baseModel, baseUrl: "https://bedrock-runtime.eu-central-1.amazonaws.com" },
		{},
		{ AWS_REGION: "us-west-2", AWS_DEFAULT_REGION: "us-east-2", AWS_BEDROCK_SKIP_AUTH: "1" },
	),
	authScenario(
		"bedrock-auth-region-precedence-default-env",
		"Bedrock AWS_DEFAULT_REGION takes precedence over endpoint-derived regions",
		{ ...baseModel, baseUrl: "https://bedrock-runtime.eu-central-1.amazonaws.com" },
		{},
		{ AWS_DEFAULT_REGION: "us-east-2", AWS_BEDROCK_SKIP_AUTH: "1" },
	),
	authScenario(
		"bedrock-auth-aws-profile-env",
		"Bedrock AWS_PROFILE suppresses endpoint-derived/default region in SDK config snapshots",
		{ ...baseModel, baseUrl: "https://bedrock-runtime.eu-central-1.amazonaws.com" },
		{},
		{ AWS_PROFILE: "fixture-env-profile" },
	),
	authScenario(
		"bedrock-auth-options-profile",
		"Bedrock options.profile is passed to SDK config without suppressing endpoint region derivation",
		{ ...baseModel, baseUrl: "https://bedrock-runtime.eu-central-1.amazonaws.com" },
		{ profile: "fixture-option-profile" },
		{},
	),
	authScenario(
		"bedrock-auth-custom-endpoint-region",
		"Bedrock custom endpoints are preserved when a region is configured",
		customEndpointModel,
		{ region: "us-west-2" },
		{ AWS_BEDROCK_SKIP_AUTH: "1" },
	),
	authScenario(
		"bedrock-auth-bearer-option",
		"Bedrock bearer token option wins over environment bearer token",
		baseModel,
		{ bearerToken: "fixture-bearer-option" },
		{ AWS_BEARER_TOKEN_BEDROCK: "fixture-bearer-env" },
	),
	authScenario(
		"bedrock-auth-bearer-env",
		"Bedrock bearer token environment auth is represented without SigV4 scope",
		baseModel,
		{},
		{ AWS_BEARER_TOKEN_BEDROCK: "fixture-bearer-env" },
	),
	authScenario(
		"bedrock-auth-skip-auth-proxy",
		"Bedrock skip-auth proxy mode suppresses bearer auth and uses proxy-safe dummy credentials",
		customEndpointModel,
		{},
		{ AWS_BEDROCK_SKIP_AUTH: "1", AWS_BEARER_TOKEN_BEDROCK: "fixture-bearer-env" },
	),
	authScenario(
		"bedrock-auth-sigv4-session",
		"Bedrock SigV4 normalized request semantics are stable under fake credentials and fixed timestamp",
		baseModel,
		{ region: "us-east-1" },
		{
			AWS_ACCESS_KEY_ID: "FIXTUREACCESSKEY",
			AWS_SECRET_ACCESS_KEY: "fixture-secret-access-key",
			AWS_SESSION_TOKEN: "fixture-session-value",
		},
	),
	authScenario(
		"bedrock-auth-missing-credentials",
		"Bedrock missing IAM credentials are represented as a local async stream error surface",
		baseModel,
		{},
		{},
	),
];

function toRuntimeModel(model: FixtureModelInput): Model<"bedrock-converse-stream"> {
	return {
		...model,
		cost: model.cost ?? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		contextWindow: 200_000,
		maxTokens: model.maxTokens ?? 4096,
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
		...(options.region !== undefined ? { region: options.region } : {}),
		...(options.profile !== undefined ? { profile: options.profile } : {}),
		...(options.bearerToken !== undefined ? { bearerToken: options.bearerToken } : {}),
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

const fixtureEnvKeys: FixtureEnvKey[] = [
	"AWS_ACCESS_KEY_ID",
	"AWS_SECRET_ACCESS_KEY",
	"AWS_SESSION_TOKEN",
	"AWS_PROFILE",
	"AWS_BEARER_TOKEN_BEDROCK",
	"AWS_REGION",
	"AWS_DEFAULT_REGION",
	"AWS_BEDROCK_SKIP_AUTH",
];

async function withScenarioEnv<T>(scenario: Scenario, action: () => Promise<T>): Promise<T> {
	const saved = Object.fromEntries(fixtureEnvKeys.map((key) => [key, process.env[key]])) as Record<
		FixtureEnvKey,
		string | undefined
	>;
	try {
		for (const key of fixtureEnvKeys) {
			process.env[key] = scenario.input.env?.[key] ?? "";
		}
		process.env.AWS_EC2_METADATA_DISABLED = "true";
		return await action();
	} finally {
		for (const key of fixtureEnvKeys) {
			const value = saved[key];
			if (value === undefined) {
				delete process.env[key];
			} else {
				process.env[key] = value;
			}
		}
	}
}

function trimTrailingSlash(value: string): string {
	return value.replace(/\/+$/, "");
}

function percentEncodePathSegment(value: string): string {
	return Array.from(Buffer.from(value, "utf8"))
		.map((byte) => {
			const char = String.fromCharCode(byte);
			if (/^[A-Za-z0-9._~-]$/.test(char)) return char;
			return `%${byte.toString(16).toUpperCase().padStart(2, "0")}`;
		})
		.join("");
}

function standardEndpointRegion(baseUrl: string): string | undefined {
	try {
		const hostname = new URL(baseUrl).hostname.toLowerCase();
		return hostname.match(/^bedrock-runtime(?:-fips)?\.([a-z0-9-]+)\.amazonaws\.com(?:\.cn)?$/)?.[1];
	} catch {
		return undefined;
	}
}

function nonEmpty(value: string | undefined): string | undefined {
	return value === undefined || value === "" ? undefined : value;
}

function scenarioEnv(scenario: Scenario, key: FixtureEnvKey): string | undefined {
	return nonEmpty(scenario.input.env?.[key]);
}

function configuredRegion(scenario: Scenario): { source: string; value?: string } {
	if (scenario.input.options.region) return { source: "options.region", value: scenario.input.options.region };
	const awsRegion = scenarioEnv(scenario, "AWS_REGION");
	if (awsRegion) return { source: "AWS_REGION", value: awsRegion };
	const awsDefaultRegion = scenarioEnv(scenario, "AWS_DEFAULT_REGION");
	if (awsDefaultRegion) return { source: "AWS_DEFAULT_REGION", value: awsDefaultRegion };
	const endpointRegion = standardEndpointRegion(scenario.input.model.baseUrl);
	if (endpointRegion && !scenarioEnv(scenario, "AWS_PROFILE")) return { source: "endpoint", value: endpointRegion };
	if (scenarioEnv(scenario, "AWS_PROFILE")) return { source: "sdk-profile-resolution" };
	return { source: "default", value: "us-east-1" };
}

function requestBaseUrl(scenario: Scenario, region: { source: string; value?: string }): { mode: string; value?: string } {
	const endpointRegion = standardEndpointRegion(scenario.input.model.baseUrl);
	const hasConfiguredRegion =
		scenario.input.options.region || scenarioEnv(scenario, "AWS_REGION") || scenarioEnv(scenario, "AWS_DEFAULT_REGION");
	const useExplicitEndpoint = !endpointRegion || (!hasConfiguredRegion && !scenarioEnv(scenario, "AWS_PROFILE"));
	if (useExplicitEndpoint) return { mode: "explicit", value: trimTrailingSlash(scenario.input.model.baseUrl) };
	if (!region.value) return { mode: "sdk-profile-resolution" };
	const suffix = region.value.startsWith("cn-") ? "amazonaws.com.cn" : "amazonaws.com";
	return { mode: "sdk-default", value: `https://bedrock-runtime.${region.value}.${suffix}` };
}

function authSnapshot(scenario: Scenario, region: { source: string; value?: string }, payload: unknown): unknown {
	// The fixture compares SigV4 semantics, not volatile SDK byte-for-byte signing internals.
	// Body hashing is normalized to the semantic field because TS command input and Zig
	// local snapshots intentionally canonicalize payload object ordering for comparison.
	void payload;
	const bearerToken = scenario.input.options.bearerToken ?? scenarioEnv(scenario, "AWS_BEARER_TOKEN_BEDROCK");
	if (scenarioEnv(scenario, "AWS_BEDROCK_SKIP_AUTH") === "1") {
		return {
			mode: "skip-auth",
			credentialSource: "proxy-dummy",
			bearerSuppressed: bearerToken !== undefined,
			secrets: "redacted",
		};
	}
	if (bearerToken) {
		return {
			mode: "bearer",
			source: scenario.input.options.bearerToken ? "options.bearerToken" : "env.bearerToken",
			token: "redacted",
			sigv4: false,
		};
	}
	if (scenario.input.options.profile || scenarioEnv(scenario, "AWS_PROFILE")) {
		return {
			mode: "profile",
			optionsProfile: scenario.input.options.profile,
			envProfile: scenarioEnv(scenario, "AWS_PROFILE"),
			credentialDiscovery: "sdk-profile-resolution",
		};
	}
	const accessKey = scenarioEnv(scenario, "AWS_ACCESS_KEY_ID");
	const secretKey = scenarioEnv(scenario, "AWS_SECRET_ACCESS_KEY");
	if (accessKey && secretKey) {
		return {
			mode: "sigv4",
			method: "POST",
			query: "",
			service: "bedrock",
			region: region.value ?? "us-east-1",
			amzDate: fixtureTimestamp.amzDate,
			credentialScope: {
				date: fixtureTimestamp.dateStamp,
				region: region.value ?? "us-east-1",
				service: "bedrock",
				terminal: "aws4_request",
			},
			signedHeaders: ["content-type", "host", "x-amz-content-sha256", "x-amz-date", "x-amz-security-token"],
			bodySha256: "normalized-payload-sha256",
			sessionToken: scenarioEnv(scenario, "AWS_SESSION_TOKEN") ? "redacted" : undefined,
			accessKeyId: "redacted",
			signature: "normalized",
		};
	}
	return {
		mode: "missing-credentials",
		errorSurface: "async-stream-error",
		message: "Bedrock requires AWS_ACCESS_KEY_ID.",
		network: "not-attempted",
	};
}

function buildRequestSurfaceSnapshot(scenario: Scenario, payload: unknown): unknown {
	const path = `/model/${percentEncodePathSegment(scenario.input.model.id)}/converse-stream`;
	const region = configuredRegion(scenario);
	const baseUrl = requestBaseUrl(scenario, region);
	return {
		method: "POST",
		path,
		url: baseUrl.value ? `${baseUrl.value}${path}` : "sdk-profile-resolution",
		endpoint: baseUrl,
		region,
		clientConfig: {
			profile: scenario.input.options.profile,
			envProfile: scenarioEnv(scenario, "AWS_PROFILE"),
			endpoint: baseUrl.mode === "explicit" ? baseUrl.value : undefined,
			region: region.value,
		},
		auth: authSnapshot(scenario, region, payload),
		redaction: "secrets-redacted",
	};
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

function bedrockExceptionEvent(key: string, payload: { message: string }): Record<string, unknown> | undefined {
	switch (key) {
		case "internalServerException":
			return { [key]: new InternalServerException({ message: payload.message, $metadata: {} }) };
		case "modelStreamErrorException":
			return { [key]: new ModelStreamErrorException({ message: payload.message, $metadata: {} }) };
		case "validationException":
			return { [key]: new ValidationException({ message: payload.message, $metadata: {} }) };
		case "throttlingException":
			return { [key]: new ThrottlingException({ message: payload.message, $metadata: {} }) };
		case "serviceUnavailableException":
			return { [key]: new ServiceUnavailableException({ message: payload.message, $metadata: {} }) };
		default:
			return undefined;
	}
}

function toSdkEvent(event: ConverseStreamFixtureEvent): Record<string, unknown> {
	const key = eventType(event);
	const payload = eventPayload(event);
	if (payload && typeof payload === "object" && "message" in payload) {
		const exception = bedrockExceptionEvent(key, payload as { message: string });
		if (exception) return exception;
	}
	return event as unknown as Record<string, unknown>;
}

function buildAbortableMockAsyncStream(
	events: ConverseStreamFixtureEvent[],
	controller: AbortController | undefined,
	abortMode: SerializableOptions["abort"],
): AsyncIterable<Record<string, unknown>> {
	return {
		async *[Symbol.asyncIterator]() {
			for (const event of events) {
				yield toSdkEvent(event);
			}
			if (abortMode === "mid") {
				controller?.abort();
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
		const type = eventType(event);
		const isException = type.endsWith("Exception");
		const headers = eventStreamHeader(isException ? ":exception-type" : ":event-type", type);
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
	const terminalMessage = event.type === "error" ? event.error : event.type === "done" ? event.message : undefined;
	return {
		type: event.type,
		...(event.contentIndex !== undefined ? { contentIndex: event.contentIndex } : {}),
		...(event.delta !== undefined ? { delta: event.delta } : {}),
		...(event.content !== undefined ? { content: event.content } : {}),
		...(event.toolCall !== undefined ? { toolCall: semanticToolCall(event.toolCall) } : {}),
		...(terminalMessage !== undefined ? { message: semanticMessage(terminalMessage) } : {}),
		...(event.type === "error" && event.error.errorMessage !== undefined ? { errorMessage: event.error.errorMessage } : {}),
	};
}

async function captureScenario(scenario: Scenario): Promise<FixtureRecord> {
	const prototype = BedrockRuntimeClient.prototype as unknown as {
		send: (command: unknown, options?: unknown) => Promise<ConverseStreamOutput>;
	};
	const originalSend = prototype.send;
	let capturedPayload: unknown;
	let capturedResponse: FixtureRecord["expected"]["onResponse"];
	let activeAbortController: AbortController | undefined;

	prototype.send = async function (command: unknown): Promise<ConverseStreamOutput> {
		const commandWithInput = command as { input?: unknown };
		capturedPayload = stableValue(commandWithInput.input);
		if (scenario.input.options.sendException === "ServiceUnavailableException") {
			throw new ServiceUnavailableException({ message: "service unavailable fixture", $metadata: {} });
		}
		return {
			$metadata: {
				httpStatusCode: 200,
				requestId: `fixture-request-${scenario.id}`,
			},
			stream: buildAbortableMockAsyncStream(
				scenario.input.localStream.events,
				activeAbortController,
				scenario.input.options.abort,
			) as ConverseStreamOutput["stream"],
		};
	};

	try {
		return await withScenarioEnv(scenario, async () => {
			const runtimeModel = toRuntimeModel(scenario.input.model);
			const runtimeContext = toRuntimeContext(scenario.input.context);
			const runtimeOptions = toRuntimeOptions(scenario.input.options);
			const abortController =
				scenario.input.options.abort === "pre" || scenario.input.options.abort === "mid" ? new AbortController() : undefined;
			activeAbortController = abortController;
			if (scenario.input.options.abort === "pre") {
				abortController?.abort();
			}
			if (abortController) {
				runtimeOptions.signal = abortController.signal;
			}
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
					: scenario.input.mode === "streamSimple"
						? streamSimple(runtimeModel, runtimeContext, runtimeOptions as SimpleStreamOptions)
						: streamBedrock(runtimeModel, runtimeContext, runtimeOptions);
			const events: SemanticEvent[] = [];
			for await (const event of stream) {
				events.push(semanticEvent(event));
			}
			const terminalEvent = events.at(-1);
			if (terminalEvent?.type !== "done" && terminalEvent?.type !== "error") {
				throw new Error(`Scenario ${scenario.id} did not complete with a terminal event`);
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
						...(scenario.input.options.requestSurface === "capture"
							? { requestSurface: buildRequestSurfaceSnapshot(scenario, capturedPayload) }
							: {}),
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
						"streamBedrock, streamSimpleBedrock, and streamSimple after TypeScript Converse command construction and before BedrockRuntimeClient.send would contact AWS",
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
		});
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

const usageCostTolerance = 1e-12;

function validateUsageNumber(recordId: string, field: string, value: number): void {
	if (!Number.isFinite(value) || value < 0) {
		throw new Error(`HARNESS_USAGE_STOP: ${recordId} invalid usage ${field}`);
	}
}

function validateUsageCost(recordId: string, field: string, actual: number, expected: number): void {
	validateUsageNumber(recordId, `cost.${field}`, actual);
	if (Math.abs(actual - expected) > usageCostTolerance) {
		throw new Error(`HARNESS_USAGE_STOP: ${recordId} corrupt usage cost.${field}`);
	}
}

function validateTerminalUsage(record: FixtureRecord, usage: SemanticMessage["usage"]): void {
	validateUsageNumber(record.id, "input", usage.input);
	validateUsageNumber(record.id, "output", usage.output);
	validateUsageNumber(record.id, "cacheRead", usage.cacheRead);
	validateUsageNumber(record.id, "cacheWrite", usage.cacheWrite);
	validateUsageNumber(record.id, "totalTokens", usage.totalTokens);
	if (usage.totalTokens !== usage.input + usage.output) {
		throw new Error(`HARNESS_USAGE_STOP: ${record.id} corrupt usage total`);
	}

	const cost = record.input.model.cost ?? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
	const expectedCost = {
		input: (cost.input / 1_000_000) * usage.input,
		output: (cost.output / 1_000_000) * usage.output,
		cacheRead: (cost.cacheRead / 1_000_000) * usage.cacheRead,
		cacheWrite: (cost.cacheWrite / 1_000_000) * usage.cacheWrite,
	};
	const expectedTotal = expectedCost.input + expectedCost.output + expectedCost.cacheRead + expectedCost.cacheWrite;
	validateUsageCost(record.id, "input", usage.cost.input, expectedCost.input);
	validateUsageCost(record.id, "output", usage.cost.output, expectedCost.output);
	validateUsageCost(record.id, "cacheRead", usage.cost.cacheRead, expectedCost.cacheRead);
	validateUsageCost(record.id, "cacheWrite", usage.cost.cacheWrite, expectedCost.cacheWrite);
	validateUsageCost(record.id, "total", usage.cost.total, expectedTotal);
}

function validateStreamEvents(record: FixtureRecord): void {
	let sawStart = false;
	let terminalCount = 0;
	const activeToolBlocks = new Set<number>();
	for (const [index, event] of record.expected.typeScriptStream.entries()) {
		if (event.type === "start") sawStart = true;
		if (!sawStart && event.type !== "start" && event.type !== "error") {
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
		if (event.type === "done" || event.type === "error") {
			terminalCount++;
			if (!event.message) {
				throw new Error(`HARNESS_STREAM_TERMINAL: ${record.id} terminal event missing message`);
			}
			if (!["stop", "length", "toolUse", "error", "aborted"].includes(event.message.stopReason)) {
				throw new Error(`HARNESS_USAGE_STOP: ${record.id} invalid stopReason ${event.message.stopReason}`);
			}
			validateTerminalUsage(record, event.message.usage);
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
		expectNegative("corrupted-usage-total-nonzero", "HARNESS_USAGE_STOP", () => {
			const record = cloneRecord(first);
			const terminal = record.expected.typeScriptStream.at(-1);
			if (terminal?.message) {
				terminal.message.usage.input = 7;
				terminal.message.usage.output = 5;
				terminal.message.usage.totalTokens = 999;
			}
			validateFixture(record);
		}),
	);
	output.push(
		expectNegative("corrupted-usage-cache-nonzero", "HARNESS_USAGE_STOP", () => {
			const source = records.find((candidate) => candidate.id === "bedrock-stream-usage-cache-total-fallback") ?? first;
			const record = cloneRecord(source);
			const terminal = record.expected.typeScriptStream.at(-1);
			if (terminal?.message) {
				terminal.message.usage.cacheRead = 13;
				terminal.message.usage.cacheWrite = 8;
			}
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
		AWS_BEDROCK_SKIP_AUTH: "",
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
