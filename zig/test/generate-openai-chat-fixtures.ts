import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "typebox";
import {
	getOpenAICompletionsCompatForTesting,
	streamOpenAICompletions,
	type OpenAICompletionsOptions,
} from "../../packages/ai/src/providers/openai-completions.js";
import type {
	AssistantMessage,
	AssistantMessageEvent,
	Context,
	Message,
	Model,
	OpenAICompletionsCompat,
	ToolCall,
} from "../../packages/ai/src/types.js";

const scriptPath = fileURLToPath(import.meta.url);
const scriptDir = dirname(scriptPath);
const repoRoot = join(scriptDir, "..", "..");
const fixtureDir = join(scriptDir, "golden", "openai-chat");
const schemaVersion = 1;
const checkMode = process.argv.includes("--check");
const fixtureApiKey = "fixture-api-key-redacted";
const maxFixtureBytes = 200_000;
const maxStringLength = 12_000;

const sourceCitations = [
	"packages/ai/src/providers/openai-completions.ts:111-153",
	"packages/ai/src/providers/openai-completions.ts:426-579",
	"packages/ai/src/providers/openai-completions.ts:582-778",
	"packages/ai/src/providers/openai-completions.ts:941-1122",
	"packages/ai/src/types.ts:278-347",
] as const;

interface FixtureModelInput {
	id: string;
	name: string;
	api: "openai-completions";
	provider: string;
	baseUrl: string;
	reasoning: boolean;
	input: ("text" | "image")[];
	headers?: Record<string, string>;
	compat?: OpenAICompletionsCompat;
}

interface SerializableOptions {
	apiKeyMode: "fixture-placeholder";
	cacheRetention?: "none" | "short" | "long" | "env-long";
	headers?: Record<string, string>;
	maxRetries?: number;
	maxTokens?: number;
	onPayload?: "pass-through" | "replace-with-fixture-payload";
	reasoningEffort?: OpenAICompletionsOptions["reasoningEffort"];
	sessionId?: string;
	temperature?: number;
	timeoutMs?: number;
	toolChoice?: OpenAICompletionsOptions["toolChoice"];
}

type WithoutTimestamp<T> = T extends { timestamp: number } ? Omit<T, "timestamp"> : T;
type DeclarativeMessage = WithoutTimestamp<Message>;

interface DeclarativeContext {
	systemPrompt?: string;
	messages: DeclarativeMessage[];
	tools?: Context["tools"];
}

interface ScenarioInput {
	model: FixtureModelInput;
	context: DeclarativeContext;
	options: SerializableOptions;
	/** Optional SSE chunks to return from the mock instead of the default stream. */
	mockChunks?: Record<string, unknown>[];
}

interface Scenario {
	id: string;
	title: string;
	input: ScenarioInput;
	onPayloadReplacement?: unknown;
}

interface CapturedRequest {
	method: string;
	url: string;
	baseUrl: string;
	path: string;
	headers: Record<string, string>;
	jsonPayload: unknown;
}

interface NormalizedAssistantMessage {
	model: string;
	responseModel?: string;
	stopReason: string;
	api: string;
	provider: string;
	usage: {
		input: number;
		output: number;
		cacheRead: number;
		cacheWrite: number;
		totalTokens: number;
	};
	content: unknown[];
}

interface FixtureRecord {
	schemaVersion: typeof schemaVersion;
	id: string;
	title: string;
	input: ScenarioInput;
	expected: {
		resolvedCompat: unknown;
		typeScriptRequest: CapturedRequest;
		onPayload?: {
			observedPayload: unknown;
			replacementPayload?: unknown;
		};
		streamOutput?: NormalizedAssistantMessage;
	};
	metadata: {
		captureBoundary: string;
		captureMethod: string;
		network: "global fetch mock rejects unhandled requests";
		sourceCitations: readonly string[];
	};
}

interface CapturedFetch {
	request: CapturedRequest;
}

const usage = {
	input: 7,
	output: 5,
	cacheRead: 0,
	cacheWrite: 0,
	totalTokens: 12,
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
} satisfies AssistantMessage["usage"];

const assistantToolCall = {
	type: "toolCall",
	id: "call_fixture_weather",
	name: "get_weather",
	arguments: { city: "Berlin", unit: "celsius" },
} satisfies ToolCall;

const assistantToolCallWithNestedArgs = {
	type: "toolCall",
	id: "call_fixture_nested",
	name: "inspect_image",
	arguments: { flags: ["safe", "deterministic"], request: { count: 2, kind: "thumbnail" } },
} satisfies ToolCall;

const baseContext = {
	systemPrompt: "You are the deterministic OpenAI Chat fixture assistant.",
	messages: [
		{
			role: "user",
			content: "Return a concise fixture response.",
		},
	],
} satisfies DeclarativeContext;

const fixtureTool = {
	name: "get_weather",
	description: "Return deterministic weather for a city.",
	parameters: Type.Object({
		city: Type.String(),
		unit: Type.Union([Type.Literal("celsius"), Type.Literal("fahrenheit")]),
	}),
};

function buildModel(overrides: Partial<FixtureModelInput> = {}): FixtureModelInput {
	return {
		id: "gpt-4.1-fixture",
		name: "GPT 4.1 Fixture",
		api: "openai-completions",
		provider: "openai",
		baseUrl: "https://api.openai.com/v1",
		reasoning: false,
		input: ["text"],
		...overrides,
	};
}

function toRuntimeModel(model: FixtureModelInput): Model<"openai-completions"> {
	return {
		...model,
		cost: { input: 0, output: 0 },
		contextWindow: 128_000,
		maxTokens: 4096,
	};
}

function toRuntimeOptions(options: SerializableOptions): OpenAICompletionsOptions {
	const { apiKeyMode: _apiKeyMode, cacheRetention, onPayload: _onPayload, ...rest } = options;
	return {
		...rest,
		...(cacheRetention && cacheRetention !== "env-long" ? { cacheRetention } : {}),
		apiKey: fixtureApiKey,
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

const scenarios: Scenario[] = [
	{
		id: "openai-basic-text",
		title: "OpenAI baseline text request captures semantic payload and auth presence",
		input: {
			model: buildModel({
				headers: { "x-fixture-model-header": "model-default" },
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "short",
				maxTokens: 64,
				sessionId: "fixture-session-basic",
				temperature: 0,
			},
		},
	},
	{
		id: "openai-base-path-trailing-slash-url",
		title: "OpenAI-compatible base URL with nested base path and trailing slash uses the submitted request URL",
		input: {
			model: buildModel({
				id: "gpt-4.1-base-path-fixture",
				name: "GPT 4.1 Base Path Fixture",
				baseUrl: "https://llm-proxy.example.test/custom/openai/v1/",
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "none",
				maxTokens: 16,
			},
		},
	},
	{
		id: "openai-on-payload-replacement",
		title: "onPayload replacement is the submitted request body",
		input: {
			model: buildModel({ id: "gpt-4.1-replacement-fixture", reasoning: true }),
			context: {
				systemPrompt: "Use replacement payload when the callback returns one.",
				messages: [{ role: "user", content: "This original prompt is replaced." }],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				maxTokens: 32,
				onPayload: "replace-with-fixture-payload",
				reasoningEffort: "low",
			},
		},
		onPayloadReplacement: {
			model: "fixture-replacement-model",
			messages: [{ role: "user", content: "payload replaced by deterministic fixture callback" }],
			stream: true,
			fixture_marker: "on-payload-replacement",
		},
	},
	{
		id: "openai-on-payload-pass-through",
		title: "onPayload pass-through preserves the final post-compat request body",
		input: {
			model: buildModel({ id: "gpt-4.1-pass-through-fixture" }),
			context: {
				systemPrompt: "Observe the post-compat payload and pass it through unchanged.",
				messages: [{ role: "user", content: "This prompt should remain in the submitted payload." }],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				maxTokens: 24,
				onPayload: "pass-through",
				temperature: 0,
			},
		},
	},
	{
		id: "header-merge-option-override",
		title: "Model headers, generated auth, session affinity, and option overrides share one capture boundary",
		input: {
			model: buildModel({
				headers: {
					"x-fixture-model-header": "model-value",
					"x-fixture-shared": "model-will-be-overridden",
				},
				compat: { sendSessionAffinityHeaders: true },
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "short",
				headers: {
					"x-fixture-option-header": "option-value",
					"x-fixture-shared": "option-wins",
				},
				maxRetries: 0,
				sessionId: "fixture-session-headers",
				timeoutMs: 1234,
			},
		},
	},
	{
		id: "chutes-max-tokens-scaffold",
		title: "Non-standard OpenAI-compatible base URL scaffold captures max_tokens compatibility",
		input: {
			model: buildModel({
				id: "qwen-fixture",
				name: "Qwen Fixture",
				provider: "chutes",
				baseUrl: "https://llm.chutes.ai/v1",
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "none",
				maxTokens: 96,
			},
		},
	},
	{
		id: "openrouter-anthropic-compat",
		title: "OpenRouter provider auto-detection captures OpenRouter thinking and Anthropic cache compat",
		input: {
			model: buildModel({
				id: "anthropic/claude-3.7-sonnet",
				name: "OpenRouter Anthropic Fixture",
				provider: "openrouter",
				baseUrl: "https://openrouter.ai/api/v1",
				reasoning: true,
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "none",
				reasoningEffort: "medium",
				sessionId: "fixture-openrouter-session",
			},
		},
	},
	{
		id: "deepseek-reasoning-replay",
		title: "DeepSeek auto-detection captures replay reasoning_content and effort map compatibility",
		input: {
			model: buildModel({
				id: "deepseek-reasoner",
				name: "DeepSeek Reasoner Fixture",
				provider: "deepseek",
				baseUrl: "https://api.deepseek.com/v1",
				reasoning: true,
			}),
			context: {
				systemPrompt: "Preserve DeepSeek assistant replay fields.",
				messages: [
					{ role: "user", content: "Replay the reasoning transcript." },
					{
						role: "assistant",
						content: [{ type: "text", text: "Prior answer without stored reasoning." }],
						api: "openai-completions",
						provider: "deepseek",
						model: "deepseek-reasoner",
						usage,
						stopReason: "stop",
					},
				],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				reasoningEffort: "xhigh",
			},
		},
	},
	{
		id: "groq-qwen3-effort-map",
		title: "Groq Qwen3 auto-detection captures provider/model-specific reasoning effort map",
		input: {
			model: buildModel({
				id: "qwen/qwen3-32b",
				name: "Groq Qwen3 Fixture",
				provider: "groq",
				baseUrl: "https://api.groq.com/openai/v1",
				reasoning: true,
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				reasoningEffort: "low",
			},
		},
	},
	{
		id: "zai-nonstandard-compat",
		title: "Z.AI auto-detection captures non-standard provider defaults and zai thinking format",
		input: {
			model: buildModel({
				id: "glm-4.5",
				name: "Z.AI Fixture",
				provider: "zai",
				baseUrl: "https://api.z.ai/api/paas/v4",
				reasoning: true,
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
			},
		},
	},
	{
		id: "xai-grok-compat",
		title: "XAI/Grok auto-detection disables OpenAI-only reasoning effort support",
		input: {
			model: buildModel({
				id: "grok-4",
				name: "Grok Fixture",
				provider: "xai",
				baseUrl: "https://api.x.ai/v1",
				reasoning: true,
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				reasoningEffort: "high",
			},
		},
	},
	{
		id: "cerebras-nonstandard-compat",
		title: "Cerebras auto-detection omits OpenAI-only request fields by default",
		input: {
			model: buildModel({
				id: "llama-4-scout",
				name: "Cerebras Fixture",
				provider: "cerebras",
				baseUrl: "https://api.cerebras.ai/v1",
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				maxTokens: 48,
			},
		},
	},
	{
		id: "cloudflare-workers-ai-compat",
		title: "Cloudflare Workers AI auto-detection captures non-standard provider defaults",
		input: {
			model: buildModel({
				id: "@cf/meta/llama-3.1-8b-instruct",
				name: "Cloudflare Workers AI Fixture",
				provider: "cloudflare-workers-ai",
				baseUrl: "https://api.cloudflare.com/client/v4/accounts/fixture/ai/v1",
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
			},
		},
	},
	{
		id: "opencode-nonstandard-compat",
		title: "opencode auto-detection captures non-standard provider defaults",
		input: {
			model: buildModel({
				id: "opencode/gpt-oss",
				name: "opencode Fixture",
				provider: "opencode",
				baseUrl: "https://api.opencode.ai/v1",
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
			},
		},
	},
	{
		id: "generic-proxy-compat",
		title: "Generic OpenAI-compatible proxy preserves OpenAI defaults when no known provider/url matches",
		input: {
			model: buildModel({
				id: "proxy-gpt",
				name: "Generic Proxy Fixture",
				provider: "custom-openai-proxy",
				baseUrl: "https://llm-proxy.example.test/openai/v1",
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				maxTokens: 24,
			},
		},
	},
	{
		id: "mixed-openrouter-deepseek-url",
		title: "Mixed provider/base URL conflict follows TypeScript provider and URL precedence exactly",
		input: {
			model: buildModel({
				id: "anthropic/mixed-deepseek",
				name: "Mixed OpenRouter DeepSeek Fixture",
				provider: "openrouter",
				baseUrl: "https://api.deepseek.com/v1",
				reasoning: true,
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "none",
				reasoningEffort: "minimal",
			},
		},
	},
	{
		id: "explicit-partial-compat-override",
		title: "Partial explicit compat override replaces only named fields and preserves detected defaults",
		input: {
			model: buildModel({
				id: "partial-compat-fixture",
				name: "Partial Compat Fixture",
				provider: "deepseek",
				baseUrl: "https://api.deepseek.com/v1",
				reasoning: true,
				compat: {
					requiresToolResultName: true,
					thinkingFormat: "openai",
					supportsReasoningEffort: false,
				},
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				reasoningEffort: "high",
			},
		},
	},
	{
		id: "explicit-false-compat-override",
		title: "Explicit false compat overrides are preserved and not replaced by detected defaults",
		input: {
			model: buildModel({
				id: "explicit-false-fixture",
				name: "Explicit False Fixture",
				provider: "openai",
				baseUrl: "https://api.openai.com/v1",
				reasoning: true,
				compat: {
					supportsStore: false,
					supportsDeveloperRole: false,
					supportsReasoningEffort: false,
					supportsUsageInStreaming: false,
					requiresToolResultName: false,
					requiresAssistantAfterToolResult: false,
					requiresThinkingAsText: false,
					requiresReasoningContentOnAssistantMessages: false,
					zaiToolStream: false,
					supportsStrictMode: false,
					sendSessionAffinityHeaders: false,
					supportsLongCacheRetention: false,
				},
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "long",
				maxTokens: 42,
				reasoningEffort: "low",
				sessionId: "fixture-explicit-false-session",
			},
		},
	},
	{
		id: "explicit-full-compat-all-fields",
		title: "Full explicit compat override records every OpenAICompletionsCompat field",
		input: {
			model: buildModel({
				id: "explicit-full-fixture",
				name: "Explicit Full Compat Fixture",
				provider: "openai",
				baseUrl: "https://openrouter.ai/api/v1",
				reasoning: true,
				compat: {
					supportsStore: false,
					supportsDeveloperRole: false,
					supportsReasoningEffort: false,
					reasoningEffortMap: {
						minimal: "tiny",
						low: "small",
						medium: "normal",
						high: "large",
						xhigh: "huge",
					},
					supportsUsageInStreaming: false,
					maxTokensField: "max_tokens",
					requiresToolResultName: true,
					requiresAssistantAfterToolResult: true,
					requiresThinkingAsText: true,
					requiresReasoningContentOnAssistantMessages: true,
					thinkingFormat: "qwen-chat-template",
					openRouterRouting: {
						allow_fallbacks: false,
						require_parameters: true,
						data_collection: "deny",
						zdr: true,
						enforce_distillable_text: true,
						order: ["OpenAI", "Anthropic"],
						only: ["OpenAI"],
						ignore: ["Other"],
						quantizations: ["fp16", "int8"],
						sort: "latency",
						max_price: { prompt: 1, completion: "2" },
						preferred_min_throughput: { p50: 10, p90: 20 },
						preferred_max_latency: 3,
					},
					vercelGatewayRouting: {
						only: ["openai"],
						order: ["anthropic", "openai"],
					},
					zaiToolStream: true,
					supportsStrictMode: false,
					cacheControlFormat: "anthropic",
					sendSessionAffinityHeaders: true,
					supportsLongCacheRetention: false,
				},
			}),
			context: {
				systemPrompt: "Bridge tool results and replay thinking as text.",
				messages: [
					{
						role: "assistant",
						content: [
							{ type: "thinking", thinking: "private fixture reasoning" },
							{ type: "text", text: "public answer" },
						],
						api: "openai-completions",
						provider: "openai",
						model: "explicit-full-fixture",
						usage,
						stopReason: "stop",
					},
					{
						role: "toolResult",
						toolCallId: "call_fixture_weather",
						toolName: "get_weather",
						content: [{ type: "text", text: "Tool result needing a bridge." }],
						isError: false,
					},
					{ role: "user", content: "Continue after the tool result." },
				],
				tools: [fixtureTool],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "none",
				maxTokens: 12,
				sessionId: "fixture-full-compat-session",
			},
		},
	},
	{
		id: "tool-choice-and-history-scaffold",
		title: "Tool definition, tool choice, assistant tool call replay, and tool result replay scaffold",
		input: {
			model: buildModel({ input: ["text", "image"] }),
			context: {
				systemPrompt: "Use the weather tool when needed.",
				messages: [
					{ role: "user", content: "What is the deterministic weather?" },
					{
						role: "assistant",
						content: [assistantToolCall],
						api: "openai-completions",
						provider: "openai",
						model: "gpt-4.1-fixture",
						usage,
						stopReason: "toolUse",
					},
					{
						role: "toolResult",
						toolCallId: "call_fixture_weather",
						toolName: "get_weather",
						content: [
							{ type: "text", text: "Weather is deterministically mild." },
							{ type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" },
						],
						isError: false,
					},
					{ role: "user", content: "Summarize it." },
				],
				tools: [fixtureTool],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				toolChoice: { type: "function", function: { name: "get_weather" } },
			},
		},
	},
	{
		id: "user-image-content",
		title: "User text and image content serializes to OpenAI image_url parts and skips empty arrays",
		input: {
			model: buildModel({
				id: "gpt-4.1-vision-fixture",
				name: "GPT 4.1 Vision Fixture",
				input: ["text", "image"],
			}),
			context: {
				systemPrompt: "Preserve user image content ordering.",
				messages: [
					{ role: "user", content: [] },
					{
						role: "user",
						content: [
							{ type: "text", text: "Inspect this fixture image." },
							{ type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" },
							{ type: "text", text: "Then answer with a caption." },
						],
					},
				],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
			},
		},
	},
	{
		id: "assistant-tool-call-replay-mixed-content",
		title: "Assistant replay preserves text joining, tool call ids, names, and JSON-stringified arguments",
		input: {
			model: buildModel(),
			context: {
				messages: [
					{
						role: "assistant",
						content: [
							{ type: "text", text: "First text part." },
							assistantToolCallWithNestedArgs,
							{ type: "text", text: "Second text part." },
						],
						api: "openai-completions",
						provider: "openai",
						model: "gpt-4.1-fixture",
						usage,
						stopReason: "toolUse",
					},
					{
						role: "assistant",
						content: [],
						api: "openai-completions",
						provider: "openai",
						model: "gpt-4.1-fixture",
						usage,
						stopReason: "stop",
					},
				],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
			},
		},
	},
	{
		id: "tool-result-consecutive-image-routing",
		title: "Consecutive text and image tool results become tool messages plus one follow-up user image batch",
		input: {
			model: buildModel({
				id: "gpt-4.1-tool-image-fixture",
				name: "GPT 4.1 Tool Image Fixture",
				input: ["text", "image"],
			}),
			context: {
				messages: [
					{
						role: "assistant",
						content: [assistantToolCall, assistantToolCallWithNestedArgs],
						api: "openai-completions",
						provider: "openai",
						model: "gpt-4.1-tool-image-fixture",
						usage,
						stopReason: "toolUse",
					},
					{
						role: "toolResult",
						toolCallId: "call_fixture_weather",
						toolName: "get_weather",
						content: [
							{ type: "text", text: "First tool text." },
							{ type: "image", data: "Zmlyc3Q=", mimeType: "image/png" },
						],
						isError: false,
					},
					{
						role: "toolResult",
						toolCallId: "call_fixture_nested",
						toolName: "inspect_image",
						content: [{ type: "image", data: "c2Vjb25k", mimeType: "image/jpeg" }],
						isError: false,
					},
				],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
			},
		},
	},
	{
		id: "empty-tools-with-prior-tool-history",
		title: "Prior assistant tool-call history emits an empty tools array when no current tools are configured",
		input: {
			model: buildModel(),
			context: {
				messages: [
					{ role: "user", content: "Use previous tool history without current tool definitions." },
					{
						role: "assistant",
						content: [assistantToolCall],
						api: "openai-completions",
						provider: "openai",
						model: "gpt-4.1-fixture",
						usage,
						stopReason: "toolUse",
					},
				],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
			},
		},
	},
	{
		id: "tool-choice-auto",
		title: "String toolChoice auto serializes as tool_choice auto",
		input: {
			model: buildModel(),
			context: {
				...baseContext,
				tools: [fixtureTool],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				toolChoice: "auto",
			},
		},
	},
	{
		id: "tool-choice-none",
		title: "String toolChoice none serializes as tool_choice none",
		input: {
			model: buildModel(),
			context: {
				...baseContext,
				tools: [fixtureTool],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				toolChoice: "none",
			},
		},
	},
	{
		id: "tool-choice-required",
		title: "String toolChoice required serializes as tool_choice required",
		input: {
			model: buildModel(),
			context: {
				...baseContext,
				tools: [fixtureTool],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				toolChoice: "required",
			},
		},
	},
	{
		id: "openai-reasoning-developer-role",
		title: "Reasoning-capable OpenAI model uses developer role after message transform",
		input: {
			model: buildModel({
				id: "o4-mini-fixture",
				name: "OpenAI Reasoning Fixture",
				reasoning: true,
			}),
			context: {
				systemPrompt: "Use the developer role only when TypeScript does.",
				messages: [
					{ role: "user", content: "Confirm role selection." },
					{
						role: "assistant",
						content: [{ type: "text", text: "Prior transformed assistant message." }],
						api: "openai-completions",
						provider: "openai",
						model: "o4-mini-fixture",
						usage,
						stopReason: "stop",
					},
				],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				maxTokens: 16,
				reasoningEffort: "minimal",
			},
		},
	},
	{
		id: "openai-reasoning-no-effort",
		title: "OpenAI-style reasoning-capable model omits reasoning_effort when no effort is requested",
		input: {
			model: buildModel({
				id: "openai-no-effort-fixture",
				name: "OpenAI No Effort Fixture",
				reasoning: true,
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
			},
		},
	},
	{
		id: "openai-reasoning-effort-map-override",
		title: "OpenAI-style reasoning_effort applies explicit reasoning effort map before serialization",
		input: {
			model: buildModel({
				id: "openai-effort-map-fixture",
				name: "OpenAI Effort Map Fixture",
				reasoning: true,
				compat: {
					reasoningEffortMap: {
						low: "fixture-low",
					},
				},
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				reasoningEffort: "low",
			},
		},
	},
	{
		id: "openai-reasoning-effort-disabled",
		title: "supportsReasoningEffort false gates only OpenAI-style reasoning_effort",
		input: {
			model: buildModel({
				id: "openai-effort-disabled-fixture",
				name: "OpenAI Effort Disabled Fixture",
				reasoning: true,
				compat: {
					supportsReasoningEffort: false,
					thinkingFormat: "openai",
				},
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				reasoningEffort: "high",
			},
		},
	},
	{
		id: "openrouter-reasoning-no-effort-none",
		title: "OpenRouter reasoning-capable model emits nested reasoning effort none without top-level effort",
		input: {
			model: buildModel({
				id: "openrouter-no-effort-fixture",
				name: "OpenRouter No Effort Fixture",
				provider: "openrouter",
				baseUrl: "https://openrouter.ai/api/v1",
				reasoning: true,
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
			},
		},
	},
	{
		id: "openrouter-reasoning-effort-map-supports-false",
		title: "OpenRouter reasoning ignores supportsReasoningEffort false and applies explicit effort map",
		input: {
			model: buildModel({
				id: "openrouter-effort-map-fixture",
				name: "OpenRouter Effort Map Fixture",
				provider: "openrouter",
				baseUrl: "https://openrouter.ai/api/v1",
				reasoning: true,
				compat: {
					supportsReasoningEffort: false,
					reasoningEffortMap: {
						high: "router-high",
					},
				},
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				reasoningEffort: "high",
			},
		},
	},
	{
		id: "deepseek-reasoning-disabled-no-effort",
		title: "DeepSeek thinking format emits disabled thinking and omits reasoning_effort without effort",
		input: {
			model: buildModel({
				id: "deepseek-disabled-fixture",
				name: "DeepSeek Disabled Fixture",
				provider: "deepseek",
				baseUrl: "https://api.deepseek.com/v1",
				reasoning: true,
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
			},
		},
	},
	{
		id: "deepseek-reasoning-map-supports-false",
		title: "DeepSeek thinking format ignores supportsReasoningEffort false and applies mapped effort",
		input: {
			model: buildModel({
				id: "deepseek-supports-false-fixture",
				name: "DeepSeek Supports False Fixture",
				provider: "deepseek",
				baseUrl: "https://api.deepseek.com/v1",
				reasoning: true,
				compat: {
					supportsReasoningEffort: false,
				},
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				reasoningEffort: "xhigh",
			},
		},
	},
	{
		id: "zai-reasoning-enabled-exclusive",
		title: "Z.AI thinking format emits enable_thinking true and omits incompatible reasoning fields",
		input: {
			model: buildModel({
				id: "glm-4.5-enabled-fixture",
				name: "Z.AI Enabled Fixture",
				provider: "zai",
				baseUrl: "https://api.z.ai/api/paas/v4",
				reasoning: true,
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				reasoningEffort: "high",
			},
		},
	},
	{
		id: "qwen-reasoning-enabled-exclusive",
		title: "Qwen thinking format emits enable_thinking true and omits incompatible reasoning fields",
		input: {
			model: buildModel({
				id: "qwen-enabled-fixture",
				name: "Qwen Enabled Fixture",
				provider: "qwen",
				baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
				reasoning: true,
				compat: {
					thinkingFormat: "qwen",
				},
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				reasoningEffort: "minimal",
			},
		},
	},
	{
		id: "qwen-reasoning-disabled-no-effort",
		title: "Qwen thinking format emits enable_thinking false and omits incompatible reasoning fields without effort",
		input: {
			model: buildModel({
				id: "qwen-disabled-no-effort-fixture",
				name: "Qwen Disabled No Effort Fixture",
				provider: "qwen",
				baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
				reasoning: true,
				compat: {
					thinkingFormat: "qwen",
				},
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
			},
		},
	},
	{
		id: "qwen-chat-template-reasoning-enabled-exclusive",
		title: "Qwen chat-template thinking format emits chat_template_kwargs and omits incompatible reasoning fields",
		input: {
			model: buildModel({
				id: "qwen-chat-template-enabled-fixture",
				name: "Qwen Chat Template Enabled Fixture",
				provider: "qwen",
				baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
				reasoning: true,
				compat: {
					thinkingFormat: "qwen-chat-template",
				},
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				reasoningEffort: "low",
			},
		},
	},
	{
		id: "nonstandard-explicit-store-usage-override",
		title: "Non-standard provider explicit compat enables store and streaming usage fields",
		input: {
			model: buildModel({
				id: "deepseek-explicit-store-fixture",
				name: "DeepSeek Explicit Store Fixture",
				provider: "deepseek",
				baseUrl: "https://api.deepseek.com/v1",
				compat: {
					supportsStore: true,
					supportsUsageInStreaming: true,
				},
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
			},
		},
	},
	{
		id: "max-tokens-explicit-compat-field",
		title: "Explicit maxTokensField override selects max_tokens exclusively",
		input: {
			model: buildModel({
				id: "explicit-max-tokens-field-fixture",
				name: "Explicit Max Tokens Field Fixture",
				compat: {
					maxTokensField: "max_tokens",
				},
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				maxTokens: 77,
			},
		},
	},
	{
		id: "tool-compat-name-and-no-strict",
		title: "Tool result name and strict omission follow explicit compat flags",
		input: {
			model: buildModel({
				id: "tool-compat-name-no-strict-fixture",
				name: "Tool Compat Name No Strict Fixture",
				compat: {
					requiresToolResultName: true,
					supportsStrictMode: false,
				},
			}),
			context: {
				systemPrompt: "Validate dedicated tool compat flags.",
				messages: [
					{
						role: "assistant",
						content: [assistantToolCall],
						api: "openai-completions",
						provider: "openai",
						model: "tool-compat-name-no-strict-fixture",
						usage,
						stopReason: "toolUse",
					},
					{
						role: "toolResult",
						toolCallId: "call_fixture_weather",
						toolName: "get_weather",
						content: [{ type: "text", text: "Named tool result." }],
						isError: false,
					},
				],
				tools: [fixtureTool],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
			},
		},
	},
	{
		id: "tool-compat-name-required-but-missing",
		title: "Required tool result name is omitted when the source tool result has no name",
		input: {
			model: buildModel({
				id: "tool-compat-missing-name-fixture",
				name: "Tool Compat Missing Name Fixture",
				compat: {
					requiresToolResultName: true,
				},
			}),
			context: {
				messages: [
					{
						role: "toolResult",
						toolCallId: "call_fixture_weather",
						toolName: "",
						content: [{ type: "text", text: "Unnamed tool result." }],
						isError: false,
					},
				],
				tools: [fixtureTool],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
			},
		},
	},
	{
		id: "openrouter-routing-full-object",
		title: "OpenRouter URL serializes the full explicit provider routing object",
		input: {
			model: buildModel({
				id: "openrouter-routing-fixture",
				name: "OpenRouter Routing Fixture",
				provider: "openrouter",
				baseUrl: "https://openrouter.ai/api/v1",
				compat: {
					openRouterRouting: {
						allow_fallbacks: false,
						require_parameters: true,
						data_collection: "deny",
						zdr: true,
						enforce_distillable_text: true,
						order: ["Anthropic", "OpenAI", "Google"],
						only: ["Anthropic", "OpenAI"],
						ignore: ["Other"],
						quantizations: ["fp16", "bf16", "int8"],
						sort: { by: "latency", partition: null },
						max_price: { prompt: 0.5, completion: "1.25", image: 0.01, audio: "0.02", request: 0 },
						preferred_min_throughput: 12,
						preferred_max_latency: { p50: 1, p75: 2, p90: 3, p99: 4 },
					},
				},
			}),
			context: baseContext,
			options: { apiKeyMode: "fixture-placeholder", cacheRetention: "none" },
		},
	},
	{
		id: "openrouter-routing-empty-object",
		title: "OpenRouter URL preserves an explicitly empty provider routing object",
		input: {
			model: buildModel({
				id: "openrouter-empty-routing-fixture",
				name: "OpenRouter Empty Routing Fixture",
				provider: "openrouter",
				baseUrl: "https://openrouter.ai/api/v1",
				compat: { openRouterRouting: {} },
			}),
			context: baseContext,
			options: { apiKeyMode: "fixture-placeholder", cacheRetention: "none" },
		},
	},
	{
		id: "openrouter-routing-non-openrouter-omitted",
		title: "OpenRouter routing compat is omitted from non-OpenRouter request bodies",
		input: {
			model: buildModel({
				id: "non-openrouter-routing-fixture",
				name: "Non OpenRouter Routing Fixture",
				compat: { openRouterRouting: { only: ["OpenAI"], order: ["OpenAI", "Anthropic"] } },
			}),
			context: baseContext,
			options: { apiKeyMode: "fixture-placeholder", cacheRetention: "none" },
		},
	},
	{
		id: "vercel-gateway-routing-only",
		title: "Vercel AI Gateway serializes providerOptions.gateway.only",
		input: {
			model: buildModel({
				id: "vercel-only-routing-fixture",
				name: "Vercel Only Routing Fixture",
				provider: "vercel-ai-gateway",
				baseUrl: "https://ai-gateway.vercel.sh/v1",
				compat: { vercelGatewayRouting: { only: ["anthropic", "openai"] } },
			}),
			context: baseContext,
			options: { apiKeyMode: "fixture-placeholder", cacheRetention: "none" },
		},
	},
	{
		id: "vercel-gateway-routing-order",
		title: "Vercel AI Gateway serializes providerOptions.gateway.order",
		input: {
			model: buildModel({
				id: "vercel-order-routing-fixture",
				name: "Vercel Order Routing Fixture",
				provider: "vercel-ai-gateway",
				baseUrl: "https://ai-gateway.vercel.sh/v1",
				compat: { vercelGatewayRouting: { order: ["openai", "anthropic"] } },
			}),
			context: baseContext,
			options: { apiKeyMode: "fixture-placeholder", cacheRetention: "none" },
		},
	},
	{
		id: "vercel-gateway-routing-combined",
		title: "Vercel AI Gateway preserves combined only/order routing order",
		input: {
			model: buildModel({
				id: "vercel-combined-routing-fixture",
				name: "Vercel Combined Routing Fixture",
				provider: "vercel-ai-gateway",
				baseUrl: "https://ai-gateway.vercel.sh/v1",
				compat: { vercelGatewayRouting: { only: ["bedrock", "openai"], order: ["bedrock", "openai"] } },
			}),
			context: baseContext,
			options: { apiKeyMode: "fixture-placeholder", cacheRetention: "none" },
		},
	},
	{
		id: "vercel-gateway-routing-empty",
		title: "Vercel AI Gateway omits providerOptions for empty routing",
		input: {
			model: buildModel({
				id: "vercel-empty-routing-fixture",
				name: "Vercel Empty Routing Fixture",
				provider: "vercel-ai-gateway",
				baseUrl: "https://ai-gateway.vercel.sh/v1",
				compat: { vercelGatewayRouting: {} },
			}),
			context: baseContext,
			options: { apiKeyMode: "fixture-placeholder", cacheRetention: "none" },
		},
	},
	{
		id: "vercel-gateway-routing-non-gateway-omitted",
		title: "Vercel routing compat is omitted for non-gateway URLs",
		input: {
			model: buildModel({
				id: "non-vercel-routing-fixture",
				name: "Non Vercel Routing Fixture",
				compat: { vercelGatewayRouting: { only: ["openai"], order: ["anthropic", "openai"] } },
			}),
			context: baseContext,
			options: { apiKeyMode: "fixture-placeholder", cacheRetention: "none" },
		},
	},
	{
		id: "prompt-cache-direct-openai-long",
		title: "Direct OpenAI long cache retention emits prompt cache key and 24h retention",
		input: {
			model: buildModel({ id: "openai-long-cache-fixture" }),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "long",
				sessionId: "fixture-openai-long-cache",
			},
		},
	},
	{
		id: "prompt-cache-direct-openai-none",
		title: "Direct OpenAI cache none omits prompt cache fields",
		input: {
			model: buildModel({ id: "openai-cache-none-fixture" }),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "none",
				sessionId: "fixture-openai-cache-none",
			},
		},
	},
	{
		id: "prompt-cache-proxy-long-supported",
		title: "Non-OpenAI proxy with long-cache support emits prompt cache key and 24h retention",
		input: {
			model: buildModel({
				id: "proxy-long-cache-fixture",
				name: "Proxy Long Cache Fixture",
				provider: "custom-openai-proxy",
				baseUrl: "https://llm-proxy.example.test/openai/v1",
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "long",
				sessionId: "fixture-proxy-long-cache",
			},
		},
	},
	{
		id: "prompt-cache-proxy-long-unsupported",
		title: "Non-OpenAI proxy without long-cache support omits prompt cache fields",
		input: {
			model: buildModel({
				id: "proxy-long-cache-unsupported-fixture",
				name: "Proxy Long Cache Unsupported Fixture",
				provider: "custom-openai-proxy",
				baseUrl: "https://llm-proxy.example.test/openai/v1",
				compat: { supportsLongCacheRetention: false },
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "long",
				sessionId: "fixture-proxy-long-cache-unsupported",
			},
		},
	},
	{
		id: "prompt-cache-long-missing-session",
		title: "Long cache retention without session emits retention but no null prompt cache key",
		input: {
			model: buildModel({ id: "openai-long-cache-missing-session-fixture" }),
			context: baseContext,
			options: { apiKeyMode: "fixture-placeholder", cacheRetention: "long" },
		},
	},
	{
		id: "prompt-cache-env-long-retention",
		title: "PI_CACHE_RETENTION=long drives long prompt cache semantics when options omit retention",
		input: {
			model: buildModel({ id: "openai-env-long-cache-fixture" }),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "env-long",
				sessionId: "fixture-env-long-cache",
			},
		},
	},
	{
		id: "session-affinity-option-overrides",
		title: "Explicit option headers override generated session-affinity headers",
		input: {
			model: buildModel({
				id: "session-affinity-override-fixture",
				compat: { sendSessionAffinityHeaders: true },
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "short",
				headers: {
					session_id: "option-session-id",
					"x-client-request-id": "option-client-request",
					"x-session-affinity": "option-affinity",
				},
				sessionId: "generated-session-should-be-overridden",
			},
		},
	},
	{
		id: "anthropic-cache-control-short-markers",
		title: "Anthropic cache-control markers apply to instruction, last tool, and last assistant text",
		input: {
			model: buildModel({
				id: "anthropic/cache-short-fixture",
				name: "Anthropic Cache Short Fixture",
				provider: "openrouter",
				baseUrl: "https://openrouter.ai/api/v1",
				compat: { cacheControlFormat: "anthropic" },
			}),
			context: {
				systemPrompt: "Cache this instruction.",
				messages: [
					{ role: "user", content: "Earlier user text is not the last conversation breakpoint." },
					{
						role: "assistant",
						content: [
							{ type: "text", text: "First assistant text." },
							{ type: "text", text: "Last assistant text gets the cache marker." },
						],
						api: "openai-completions",
						provider: "openrouter",
						model: "anthropic/cache-short-fixture",
						usage,
						stopReason: "stop",
					},
				],
				tools: [fixtureTool],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "short",
				sessionId: "fixture-anthropic-cache-short",
			},
		},
	},
	{
		id: "anthropic-cache-control-long-ttl",
		title: "Anthropic long cache-control markers include ttl 1h when long cache is supported",
		input: {
			model: buildModel({
				id: "anthropic/cache-long-fixture",
				name: "Anthropic Cache Long Fixture",
				provider: "openrouter",
				baseUrl: "https://openrouter.ai/api/v1",
				compat: { cacheControlFormat: "anthropic" },
			}),
			context: {
				systemPrompt: "Cache this long-retention instruction.",
				messages: [{ role: "user", content: "Last user text gets long cache control." }],
				tools: [fixtureTool],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "long",
				sessionId: "fixture-anthropic-cache-long",
			},
		},
	},
	{
		id: "anthropic-cache-control-long-unsupported",
		title: "Anthropic long cache-control markers omit ttl when long cache is unsupported",
		input: {
			model: buildModel({
				id: "anthropic/cache-long-unsupported-fixture",
				name: "Anthropic Cache Long Unsupported Fixture",
				compat: { cacheControlFormat: "anthropic", supportsLongCacheRetention: false },
			}),
			context: {
				systemPrompt: "Cache without long ttl support.",
				messages: [{ role: "user", content: "Last user text gets short cache control shape." }],
				tools: [fixtureTool],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "long",
				sessionId: "fixture-anthropic-cache-long-unsupported",
			},
		},
	},
	{
		id: "anthropic-cache-control-no-text-breakpoints",
		title: "Anthropic cache control does not rewrite non-text content to carry markers",
		input: {
			model: buildModel({
				id: "anthropic/cache-no-text-fixture",
				name: "Anthropic Cache No Text Fixture",
				input: ["text", "image"],
				compat: { cacheControlFormat: "anthropic" },
			}),
			context: {
				messages: [
					{
						role: "user",
						content: [{ type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" }],
					},
				],
			},
			options: { apiKeyMode: "fixture-placeholder", cacheRetention: "short" },
		},
	},
	{
		id: "anthropic-cache-control-cache-none",
		title: "Cache retention none suppresses Anthropic cache-control markers",
		input: {
			model: buildModel({
				id: "anthropic/cache-none-fixture",
				name: "Anthropic Cache None Fixture",
				provider: "openrouter",
				baseUrl: "https://openrouter.ai/api/v1",
				compat: { cacheControlFormat: "anthropic" },
			}),
			context: {
				systemPrompt: "This instruction should not receive cache control.",
				messages: [{ role: "user", content: "This user text should not receive cache control." }],
				tools: [fixtureTool],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "none",
				sessionId: "fixture-anthropic-cache-none",
			},
		},
	},
	{
		id: "response-model-routed",
		title: "Routed chunk.model sets responseModel while requested model remains unchanged",
		input: {
			model: buildModel({
				id: "openrouter/auto",
				name: "OpenRouter Auto Fixture",
				provider: "openrouter",
				baseUrl: "https://openrouter.ai/api/v1",
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
			},
			mockChunks: [
				{
					id: "chatcmpl-routed",
					object: "chat.completion.chunk",
					model: "anthropic/claude-opus-4.7",
					choices: [{ index: 0, delta: { role: "assistant", content: "routed" }, finish_reason: null }],
				},
				{
					id: "chatcmpl-routed",
					object: "chat.completion.chunk",
					model: "anthropic/claude-opus-4.7",
					choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
					usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
				},
			],
		},
	},
	{
		id: "response-model-echoed",
		title: "Echoed chunk.model matching requested id omits responseModel",
		input: {
			model: buildModel({
				id: "openrouter/auto",
				name: "OpenRouter Auto Fixture",
				provider: "openrouter",
				baseUrl: "https://openrouter.ai/api/v1",
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
			},
			mockChunks: [
				{
					id: "chatcmpl-echoed",
					object: "chat.completion.chunk",
					model: "openrouter/auto",
					choices: [{ index: 0, delta: { role: "assistant", content: "echoed" }, finish_reason: null }],
				},
				{
					id: "chatcmpl-echoed",
					object: "chat.completion.chunk",
					model: "openrouter/auto",
					choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
					usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
				},
			],
		},
	},
	{
		id: "response-model-missing-empty",
		title: "Missing and empty chunk.model does not set responseModel",
		input: {
			model: buildModel({
				id: "openrouter/auto",
				name: "OpenRouter Auto Fixture",
				provider: "openrouter",
				baseUrl: "https://openrouter.ai/api/v1",
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
			},
			mockChunks: [
				{
					id: "chatcmpl-missing",
					object: "chat.completion.chunk",
					choices: [{ index: 0, delta: { role: "assistant", content: "no-model" }, finish_reason: null }],
				},
				{
					id: "chatcmpl-missing",
					object: "chat.completion.chunk",
					model: "",
					choices: [{ index: 0, delta: { content: "!" }, finish_reason: null }],
				},
				{
					id: "chatcmpl-missing",
					object: "chat.completion.chunk",
					choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
					usage: { prompt_tokens: 1, completion_tokens: 2, total_tokens: 3 },
				},
			],
		},
	},
	{
		id: "response-model-sticky",
		title: "First concrete routed model is sticky even when later chunks differ",
		input: {
			model: buildModel({
				id: "openrouter/auto",
				name: "OpenRouter Auto Fixture",
				provider: "openrouter",
				baseUrl: "https://openrouter.ai/api/v1",
			}),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
			},
			mockChunks: [
				{
					id: "chatcmpl-sticky",
					object: "chat.completion.chunk",
					model: "anthropic/claude-opus-4.7",
					choices: [{ index: 0, delta: { role: "assistant", content: "first" }, finish_reason: null }],
				},
				{
					id: "chatcmpl-sticky",
					object: "chat.completion.chunk",
					model: "google/gemini-2.5-pro",
					choices: [{ index: 0, delta: { content: " then second" }, finish_reason: null }],
				},
				{
					id: "chatcmpl-sticky",
					object: "chat.completion.chunk",
					model: "google/gemini-2.5-pro",
					choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
					usage: { prompt_tokens: 5, completion_tokens: 3, total_tokens: 8 },
				},
			],
		},
	},
	{
		id: "composed-tool-history-reasoning-routing-cache-compat",
		title: "Composed tool history, OpenRouter reasoning, routing, cache, and explicit compat overrides",
		input: {
			model: buildModel({
				id: "anthropic/composed-cross-fixture",
				name: "Composed Cross Regression Fixture",
				provider: "openrouter",
				baseUrl: "https://openrouter.ai/api/v1",
				reasoning: true,
				compat: {
					supportsStore: false,
					supportsDeveloperRole: false,
					supportsUsageInStreaming: false,
					maxTokensField: "max_tokens",
					requiresToolResultName: true,
					requiresAssistantAfterToolResult: true,
					thinkingFormat: "openrouter",
					openRouterRouting: {
						allow_fallbacks: false,
						require_parameters: true,
						order: ["Anthropic", "OpenAI"],
						only: ["Anthropic"],
					},
					supportsStrictMode: false,
					cacheControlFormat: "anthropic",
					sendSessionAffinityHeaders: true,
					supportsLongCacheRetention: true,
				},
			}),
			context: {
				systemPrompt: "Compose routing, cache, reasoning, and tool history in one request.",
				messages: [
					{ role: "user", content: "Use the weather tool through the routed provider." },
					{
						role: "assistant",
						content: [
							{ type: "thinking", thinking: "Route to the preferred provider and preserve tool history." },
							{ type: "text", text: "I will inspect deterministic weather." },
							assistantToolCall,
						],
						api: "openai-completions",
						provider: "openrouter",
						model: "anthropic/composed-cross-fixture",
						usage,
						stopReason: "toolUse",
					},
					{
						role: "toolResult",
						toolCallId: "call_fixture_weather",
						toolName: "get_weather",
						content: [{ type: "text", text: "Composed weather result." }],
						isError: false,
					},
					{ role: "user", content: "Return the cached routed summary." },
				],
				tools: [fixtureTool],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "long",
				headers: { "x-fixture-composed": "option-header" },
				maxTokens: 99,
				reasoningEffort: "high",
				sessionId: "fixture-composed-cross-session",
				toolChoice: { type: "function", function: { name: "get_weather" } },
			},
		},
	},
];

function stableValue(value: unknown): unknown {
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

function normalizeHeaders(headers: Headers): Record<string, string> {
	const semanticHeaders: Record<string, string> = {};
	for (const [rawName, rawValue] of headers.entries()) {
		const name = rawName.toLowerCase();
		if (name === "authorization") {
			semanticHeaders[name] = rawValue.length > 0 ? "<redacted-present>" : "<redacted-empty>";
		} else if (
			name === "content-type" ||
			name === "session_id" ||
			name === "x-client-request-id" ||
			name === "x-session-affinity" ||
			name.startsWith("x-fixture-")
		) {
			semanticHeaders[name] = rawValue;
		}
	}
	return stableValue(semanticHeaders) as Record<string, string>;
}

function normalizeUrl(rawUrl: string, scenario: Scenario): Pick<CapturedRequest, "baseUrl" | "path" | "url"> {
	const capturedUrl = new URL(rawUrl);
	const modelBaseUrl = new URL(scenario.input.model.baseUrl);
	const path = capturedUrl.pathname;
	return {
		baseUrl: scenario.input.model.baseUrl,
		path,
		url: `${modelBaseUrl.origin}${path}`,
	};
}

function buildMockStream(): ReadableStream<Uint8Array> {
	const encoder = new TextEncoder();
	return new ReadableStream<Uint8Array>({
		start(controller) {
			const chunks = [
				{
					id: "chatcmpl_fixture",
					object: "chat.completion.chunk",
					created: 0,
					model: "fixture-model",
					choices: [{ index: 0, delta: { role: "assistant", content: "fixture" }, finish_reason: null }],
				},
				{
					id: "chatcmpl_fixture",
					object: "chat.completion.chunk",
					created: 0,
					model: "fixture-model",
					choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
					usage: { prompt_tokens: 7, completion_tokens: 5, total_tokens: 12 },
				},
			];
			for (const chunk of chunks) {
				controller.enqueue(encoder.encode(`data: ${JSON.stringify(chunk)}\n\n`));
			}
			controller.enqueue(encoder.encode("data: [DONE]\n\n"));
			controller.close();
		},
	});
}

function buildCustomMockStream(chunks: Record<string, unknown>[]): ReadableStream<Uint8Array> {
	const encoder = new TextEncoder();
	return new ReadableStream<Uint8Array>({
		start(controller) {
			for (const chunk of chunks) {
				controller.enqueue(encoder.encode(`data: ${JSON.stringify(chunk)}\n\n`));
			}
			controller.enqueue(encoder.encode("data: [DONE]\n\n"));
			controller.close();
		},
	});
}

function normalizeAssistantMessage(message: AssistantMessage): NormalizedAssistantMessage {
	const result: NormalizedAssistantMessage = {
		model: message.model,
		stopReason: message.stopReason,
		api: message.api,
		provider: message.provider,
		usage: {
			input: message.usage.input,
			output: message.usage.output,
			cacheRead: message.usage.cacheRead,
			cacheWrite: message.usage.cacheWrite,
			totalTokens: message.usage.totalTokens,
		},
		content: message.content.map((block) => {
			if (block.type === "text") {
				return { type: "text", text: block.text };
			}
			if (block.type === "thinking") {
				return { type: "thinking", thinking: block.thinking, redacted: block.redacted ?? false };
			}
			if (block.type === "toolCall") {
				return { type: "toolCall", id: block.id, name: block.name, arguments: block.arguments };
			}
			if (block.type === "image") {
				return { type: "image", data: block.data, mimeType: block.mimeType };
			}
			return block;
		}),
	};
	if (message.responseModel !== undefined) {
		result.responseModel = message.responseModel;
	}
	return result;
}

async function captureScenario(scenario: Scenario): Promise<FixtureRecord> {
	const originalFetch = globalThis.fetch;
	const originalCacheRetention = process.env.PI_CACHE_RETENTION;
	const allowedOrigin = new URL(scenario.input.model.baseUrl).origin;
	let capturedFetch: CapturedFetch | undefined;
	let observedPayload: unknown;
	const runtimeModel = toRuntimeModel(scenario.input.model);
	const resolvedCompat = stableValue(getOpenAICompletionsCompatForTesting(runtimeModel));

	if (scenario.input.options.cacheRetention === "env-long") {
		process.env.PI_CACHE_RETENTION = "long";
	} else {
		delete process.env.PI_CACHE_RETENTION;
	}

	globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
		const request = input instanceof Request ? input : new Request(input, init);
		const requestUrl = new URL(request.url);
		if (requestUrl.origin !== allowedOrigin) {
			throw new Error(`Blocked unmocked OpenAI Chat fixture network egress: ${request.url}`);
		}
		const rawBody = await request.text();
		capturedFetch = {
			request: {
				method: request.method,
				...normalizeUrl(request.url, scenario),
				headers: normalizeHeaders(request.headers),
				jsonPayload: rawBody.length > 0 ? (JSON.parse(rawBody) as unknown) : null,
			},
		};
		return new Response(
			scenario.input.mockChunks ? buildCustomMockStream(scenario.input.mockChunks) : buildMockStream(),
			{
				status: 200,
				headers: {
					"content-type": "text/event-stream",
					"x-fixture-response": scenario.id,
				},
			},
		);
	};

	try {
		const runtimeOptions = toRuntimeOptions(scenario.input.options);
		if (scenario.input.options.onPayload) {
			runtimeOptions.onPayload = (payload) => {
				observedPayload = payload;
				if (scenario.input.options.onPayload === "replace-with-fixture-payload") {
					return scenario.onPayloadReplacement;
				}
				return undefined;
			};
		}

		const stream = streamOpenAICompletions(
			runtimeModel,
			toRuntimeContext(scenario.input.context),
			runtimeOptions,
		);
		const events: AssistantMessageEvent[] = [];
		for await (const event of stream) {
			events.push(event);
		}
		const terminalEvent = events.at(-1);
		if (terminalEvent?.type !== "done") {
			throw new Error(`Scenario ${scenario.id} did not complete with a done event`);
		}
		if (!capturedFetch) {
			throw new Error(`Scenario ${scenario.id} did not capture an OpenAI Chat request`);
		}

		return {
			schemaVersion,
			id: scenario.id,
			title: scenario.title,
			input: scenario.input,
			expected: {
				resolvedCompat,
				typeScriptRequest: capturedFetch.request,
				...(scenario.input.options.onPayload
					? {
							onPayload: {
								observedPayload,
								...(scenario.onPayloadReplacement === undefined
									? {}
									: { replacementPayload: scenario.onPayloadReplacement }),
							},
						}
					: {}),
				...(scenario.input.mockChunks
					? {
							streamOutput: normalizeAssistantMessage(
								terminalEvent.message as AssistantMessage,
							),
						}
					: {}),
			},
			metadata: {
				captureBoundary:
					"streamOpenAICompletions after compat resolution, message/tool conversion, header merge, and onPayload mutation; before any live HTTP request",
				captureMethod:
					"global fetch is replaced with a deterministic local mock that records the SDK request and returns fixed SSE chunks",
				network: "global fetch mock rejects unhandled requests",
				sourceCitations,
			},
		};
	} finally {
		globalThis.fetch = originalFetch;
		if (originalCacheRetention === undefined) {
			delete process.env.PI_CACHE_RETENTION;
		} else {
			process.env.PI_CACHE_RETENTION = originalCacheRetention;
		}
	}
}

function validateNoVolatileStrings(value: unknown, path: string): void {
	if (typeof value === "string") {
		if (value.length > maxStringLength) {
			throw new Error(`${path} exceeds ${maxStringLength} characters`);
		}
		const forbidden = [repoRoot, scriptDir, "/Users/", "file://", "Bearer ", "sk-"];
		for (const marker of forbidden) {
			if (value.includes(marker)) {
				throw new Error(`${path} contains volatile or secret-like marker ${JSON.stringify(marker)}`);
			}
		}
		return;
	}
	if (Array.isArray(value)) {
		value.forEach((item, index) => validateNoVolatileStrings(item, `${path}[${index}]`));
		return;
	}
	if (value && typeof value === "object") {
		for (const [key, child] of Object.entries(value)) {
			if (key === "timestamp" || key === "created") {
				throw new Error(`${path}.${key} contains a volatile timestamp field`);
			}
			validateNoVolatileStrings(child, `${path}.${key}`);
		}
	}
}

function validateFixture(record: FixtureRecord): void {
	const allowedTopLevelKeys = ["expected", "id", "input", "metadata", "schemaVersion", "title"];
	for (const key of Object.keys(record)) {
		if (!allowedTopLevelKeys.includes(key)) {
			throw new Error(`Fixture ${record.id} contains unknown top-level key ${key}`);
		}
	}
	if (record.schemaVersion !== schemaVersion) {
		throw new Error(`Fixture ${record.id} has unsupported schemaVersion ${String(record.schemaVersion)}`);
	}
	if (!record.input || !record.expected?.typeScriptRequest) {
		throw new Error(`Fixture ${record.id} must include input and expected.typeScriptRequest`);
	}
	if (!record.id || !/^[a-z0-9][a-z0-9-]*$/.test(record.id)) {
		throw new Error(`Fixture ${record.id} must have a stable kebab-case id`);
	}
	const serialized = stableStringify(record);
	if (Buffer.byteLength(serialized) > maxFixtureBytes) {
		throw new Error(`Fixture ${record.id} exceeds ${maxFixtureBytes} bytes`);
	}
	validateNoVolatileStrings(record, record.id);
}

function validateRecords(records: FixtureRecord[]): void {
	const ids = new Set<string>();
	for (const record of records) {
		if (ids.has(record.id)) {
			throw new Error(`Duplicate OpenAI Chat fixture id ${record.id}`);
		}
		ids.add(record.id);
		validateFixture(record);
	}
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
		generatedBy: "zig/test/generate-openai-chat-fixtures.ts",
		fixtureCount: records.length,
		scenarioIds: records.map((record) => record.id),
		captureBoundary:
			"TypeScript OpenAI Chat request after compat/message/tool/header/onPayload processing and before live HTTP",
		network: "local mocked global fetch only; unhandled requests throw",
		sourceCitations,
	};
}

async function buildRecords(): Promise<FixtureRecord[]> {
	const savedEnv = {
		OPENAI_API_KEY: process.env.OPENAI_API_KEY,
		OPENROUTER_API_KEY: process.env.OPENROUTER_API_KEY,
		VERCEL_AI_GATEWAY_API_KEY: process.env.VERCEL_AI_GATEWAY_API_KEY,
	};
	process.env.OPENAI_API_KEY = "fixture-env-sentinel-not-read";
	process.env.OPENROUTER_API_KEY = "fixture-env-sentinel-not-read";
	process.env.VERCEL_AI_GATEWAY_API_KEY = "fixture-env-sentinel-not-read";
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
		errors.push(`Missing OpenAI Chat manifest: ${relative(scriptDir, manifestPath())}`);
	} else if (readFileSync(manifestPath(), "utf8") !== manifest) {
		errors.push(`Fixture drift for manifest: ${relative(scriptDir, manifestPath())}`);
	}

	if (existsSync(fixtureDir)) {
		for (const file of readdirSync(fixtureDir)) {
			if (file.endsWith(".json") && !expectedFiles.has(file)) {
				errors.push(`Unexpected OpenAI Chat fixture file: ${relative(scriptDir, join(fixtureDir, file))}`);
			}
		}
	}

	if (errors.length > 0) {
		throw new Error(
			`OpenAI Chat fixtures are stale. Run \`npx tsx test/generate-openai-chat-fixtures.ts\`.\n${errors.join("\n")}`,
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
	if (checkMode) {
		checkFiles(records);
		console.log(`OpenAI Chat fixtures are up to date (${records.length} scenarios)`);
	} else {
		writeFiles(records);
		console.log(`Wrote ${records.length} OpenAI Chat fixtures to ${relative(process.cwd(), fixtureDir)}`);
	}
}

main().catch((error: unknown) => {
	const message = error instanceof Error ? error.message : String(error);
	console.error(message);
	process.exitCode = 1;
});
