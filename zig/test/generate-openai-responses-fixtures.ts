import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "typebox";
import {
	streamAzureOpenAIResponses,
	type AzureOpenAIResponsesOptions,
} from "../../packages/ai/src/providers/azure-openai-responses.js";
import {
	streamOpenAICodexResponses,
	type OpenAICodexResponsesOptions,
} from "../../packages/ai/src/providers/openai-codex-responses.js";
import {
	streamOpenAIResponses,
	type OpenAIResponsesOptions,
} from "../../packages/ai/src/providers/openai-responses.js";
import type { AssistantMessageEvent, Context, Message, Model } from "../../packages/ai/src/types.js";

const scriptPath = fileURLToPath(import.meta.url);
const scriptDir = dirname(scriptPath);
const repoRoot = join(scriptDir, "..", "..");
const fixtureDir = join(scriptDir, "golden", "openai-responses");
const schemaVersion = 1;
const checkMode = process.argv.includes("--check");
const maxFixtureBytes = 180_000;
const maxStringLength = 12_000;
const fixtureApiKey = "fixture-api-key-redacted";
const fakeCodexJwt = buildFakeJwt("fixture-account");

const sourceCitations = [
	"packages/ai/src/providers/openai-responses.ts",
	"packages/ai/src/providers/openai-responses-shared.ts",
	"packages/ai/src/providers/github-copilot-headers.ts",
	"packages/ai/src/providers/azure-openai-responses.ts",
	"packages/ai/src/providers/openai-codex-responses.ts",
] as const;

const requiredCategories = ["openai", "github-copilot", "azure-openai", "openai-codex"] as const;

type ProviderFamily = (typeof requiredCategories)[number];
type ResponsesApi = "openai-responses" | "azure-openai-responses" | "openai-codex-responses";
type WithoutTimestamp<T> = T extends { timestamp: number } ? Omit<T, "timestamp"> : T;
type DeclarativeMessage = WithoutTimestamp<Message>;

interface FixtureModelInput {
	id: string;
	name: string;
	api: ResponsesApi;
	provider: string;
	baseUrl: string;
	reasoning: boolean;
	input: ("text" | "image")[];
	headers?: Record<string, string>;
	compat?: Record<string, unknown>;
}

interface SerializableOptions {
	apiKeyMode: "fixture-placeholder" | "fixture-codex-jwt";
	cacheRetention?: "none" | "short" | "long" | "env-long";
	headers?: Record<string, string>;
	maxRetries?: number;
	maxTokens?: number;
	onPayload?: "pass-through" | "replace-with-fixture-payload";
	payloadReplacement?: unknown;
	reasoningEffort?: "minimal" | "low" | "medium" | "high" | "xhigh";
	reasoningSummary?: "auto" | "detailed" | "concise" | "off" | "on" | null;
	serviceTier?: "auto" | "default" | "flex" | "priority";
	sessionId?: string;
	temperature?: number;
	textVerbosity?: "low" | "medium" | "high";
	timeoutMs?: number;
	transport?: "sse" | "auto" | "websocket";
	azureApiVersion?: string;
	azureBaseUrl?: string;
	azureDeploymentName?: string;
	azureResourceName?: string;
}

interface DeclarativeContext {
	systemPrompt?: string;
	messages: DeclarativeMessage[];
	tools?: Context["tools"];
}

interface ScenarioInput {
	model: FixtureModelInput;
	context: DeclarativeContext;
	options: SerializableOptions;
}

interface Scenario {
	id: string;
	title: string;
	providerFamily: ProviderFamily;
	input: ScenarioInput;
	onPayloadReplacement?: unknown;
}

interface CapturedRequest {
	method: string;
	url: string;
	baseUrl: string;
	path: string;
	query: Record<string, string>;
	headers: Record<string, string>;
	jsonPayload: unknown;
	requestOptions: {
		timeoutMs?: number;
		maxRetries?: number;
		signal?: "not-provided" | "provided";
	};
	transportMetadata: {
		mode: "sse" | "deferred-websocket";
		mockedStatus: number;
		mockedResponseHeaders: Record<string, string>;
		providerFamily: ProviderFamily;
		requestBoundary: string;
	};
}

interface FixtureRecord {
	schemaVersion: typeof schemaVersion;
	id: string;
	title: string;
	providerFamily: ProviderFamily;
	input: ScenarioInput;
	expected: {
		typeScriptRequest: CapturedRequest;
		onPayload?: {
			observedPayload: unknown;
			replacementPayload?: unknown;
		};
	};
	metadata: {
		captureBoundary: string;
		captureMethod: string;
		diffOutputBoundBytes: number;
		network: "global fetch mock rejects unhandled requests";
		sourceCitations: readonly string[];
	};
}

interface CapturedFetch {
	request: CapturedRequest;
}

const fixtureTool = {
	name: "lookup_fixture",
	description: "Return deterministic fixture data.",
	parameters: Type.Object({ query: Type.String() }),
};

const baseContext = {
	systemPrompt: "You are the deterministic Responses fixture assistant.",
	messages: [{ role: "user", content: "Return a concise fixture response." }],
} satisfies DeclarativeContext;

function buildOpenAIModel(overrides: Partial<FixtureModelInput> = {}): FixtureModelInput {
	return {
		id: "gpt-4.1-responses-fixture",
		name: "GPT 4.1 Responses Fixture",
		api: "openai-responses",
		provider: "openai",
		baseUrl: "https://api.openai.com/v1",
		reasoning: false,
		input: ["text"],
		...overrides,
	};
}

function buildAzureModel(overrides: Partial<FixtureModelInput> = {}): FixtureModelInput {
	return {
		id: "gpt-4.1-azure-fixture",
		name: "GPT 4.1 Azure Fixture",
		api: "azure-openai-responses",
		provider: "azure-openai-responses",
		baseUrl: "https://fixture-resource.openai.azure.com",
		reasoning: false,
		input: ["text"],
		...overrides,
	};
}

function buildCodexModel(overrides: Partial<FixtureModelInput> = {}): FixtureModelInput {
	return {
		id: "gpt-5.1-codex",
		name: "GPT 5.1 Codex Fixture",
		api: "openai-codex-responses",
		provider: "openai-codex",
		baseUrl: "https://chatgpt.com/backend-api",
		reasoning: true,
		input: ["text"],
		...overrides,
	};
}

const scenarios: Scenario[] = [
	{
		id: "openai-responses-basic-request",
		title: "OpenAI Responses baseline captures payload, headers, request options, and SSE transport metadata",
		providerFamily: "openai",
		input: {
			model: buildOpenAIModel({ headers: { "x-fixture-model-header": "model-openai" } }),
			context: { ...baseContext, tools: [fixtureTool] },
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "short",
				headers: { "x-fixture-option-header": "option-openai" },
				maxRetries: 0,
				maxTokens: 64,
				sessionId: "fixture-openai-session",
				temperature: 0,
				timeoutMs: 1234,
			},
		},
	},
	{
		id: "copilot-responses-dynamic-headers",
		title: "GitHub Copilot Responses captures static model headers, dynamic headers, and option override precedence",
		providerFamily: "github-copilot",
		input: {
			model: buildOpenAIModel({
				id: "gpt-4.1-copilot-fixture",
				name: "GitHub Copilot Responses Fixture",
				provider: "github-copilot",
				reasoning: true,
				input: ["text", "image"],
				headers: {
					"User-Agent": "GitHubCopilotChat/0.35.0",
					"Editor-Version": "vscode/1.107.0",
					"Editor-Plugin-Version": "copilot-chat/0.35.0",
					"Copilot-Integration-Id": "vscode-chat",
				},
			}),
			context: {
				messages: [
					{
						role: "user",
						content: [
							{ type: "text", text: "Describe this fixture image." },
							{ type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" },
						],
					},
				],
			},
			options: {
				apiKeyMode: "fixture-placeholder",
				cacheRetention: "short",
				headers: { "x-fixture-option-header": "option-copilot" },
				sessionId: "fixture-copilot-session",
			},
		},
	},
	{
		id: "azure-responses-basic-override-request",
		title: "Azure OpenAI Responses captures request-scoped base URL, API version, deployment, headers, and payload",
		providerFamily: "azure-openai",
		input: {
			model: buildAzureModel({ headers: { "x-fixture-model-header": "model-azure" } }),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-placeholder",
				azureApiVersion: "2025-03-01-preview",
				azureDeploymentName: "fixture-deployment",
				azureResourceName: "fixture-resource-override",
				headers: { "x-fixture-option-header": "option-azure" },
				maxRetries: 1,
				maxTokens: 32,
				sessionId: "fixture-azure-session",
				timeoutMs: 2345,
			},
		},
	},
	{
		id: "codex-responses-sse-basic-request",
		title: "OpenAI Codex Responses SSE captures fake JWT account headers, low text verbosity, and SSE body",
		providerFamily: "openai-codex",
		input: {
			model: buildCodexModel({ headers: { "x-fixture-model-header": "model-codex" } }),
			context: baseContext,
			options: {
				apiKeyMode: "fixture-codex-jwt",
				cacheRetention: "short",
				headers: { "x-fixture-option-header": "option-codex" },
				serviceTier: "default",
				sessionId: "fixture-codex-session",
				transport: "sse",
			},
		},
	},
	{
		id: "openai-responses-on-payload-replacement",
		title: "OpenAI Responses onPayload replacement is captured at the final request boundary",
		providerFamily: "openai",
		input: {
			model: buildOpenAIModel({ id: "gpt-4.1-responses-replacement-fixture" }),
			context: { messages: [{ role: "user", content: "This original prompt is replaced." }] },
			options: {
				apiKeyMode: "fixture-placeholder",
				onPayload: "replace-with-fixture-payload",
				payloadReplacement: {
					model: "fixture-replacement-model",
					input: [{ role: "user", content: [{ type: "input_text", text: "payload replaced by deterministic fixture callback" }] }],
					stream: true,
					fixture_marker: "responses-on-payload-replacement",
				},
			},
		},
	},
];

function buildFakeJwt(accountId: string): string {
	const encode = (value: unknown) =>
		Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
	return `${encode({ alg: "none", typ: "JWT" })}.${encode({ "https://api.openai.com/auth": { chatgpt_account_id: accountId } })}.fixture`;
}

function stableValue(value: unknown): unknown {
	if (Array.isArray(value)) return value.map((item) => stableValue(item));
	if (value && typeof value === "object") {
		const output: Record<string, unknown> = {};
		for (const key of Object.keys(value).sort()) {
			const child = (value as Record<string, unknown>)[key];
			if (child !== undefined) output[key] = stableValue(child);
		}
		return output;
	}
	return value;
}

function stableStringify(value: unknown): string {
	return `${JSON.stringify(stableValue(value), null, 2)}\n`;
}

function toRuntimeModel<TApi extends ResponsesApi>(model: FixtureModelInput): Model<TApi> {
	return {
		...model,
		cost: { input: 0, output: 0 },
		contextWindow: 128_000,
		maxTokens: 4096,
	} as Model<TApi>;
}

function toRuntimeContext(context: DeclarativeContext): Context {
	return {
		...context,
		messages: context.messages.map((message, index) => ({ ...message, timestamp: 1_700_000_000_000 + index })) as Context["messages"],
	};
}

function commonRuntimeOptions(options: SerializableOptions): OpenAIResponsesOptions {
	return {
		...(options.cacheRetention && options.cacheRetention !== "env-long" ? { cacheRetention: options.cacheRetention } : {}),
		...(options.headers ? { headers: options.headers } : {}),
		...(options.maxRetries !== undefined ? { maxRetries: options.maxRetries } : {}),
		...(options.maxTokens !== undefined ? { maxTokens: options.maxTokens } : {}),
		...(options.reasoningEffort ? { reasoningEffort: options.reasoningEffort } : {}),
		...(options.reasoningSummary !== undefined && (options.reasoningSummary === null || options.reasoningSummary === "auto" || options.reasoningSummary === "detailed" || options.reasoningSummary === "concise")
			? { reasoningSummary: options.reasoningSummary }
			: {}),
		...(options.serviceTier ? { serviceTier: options.serviceTier } : {}),
		...(options.sessionId ? { sessionId: options.sessionId } : {}),
		...(options.temperature !== undefined ? { temperature: options.temperature } : {}),
		...(options.timeoutMs !== undefined ? { timeoutMs: options.timeoutMs } : {}),
		apiKey: options.apiKeyMode === "fixture-codex-jwt" ? fakeCodexJwt : fixtureApiKey,
	};
}

function toAzureRuntimeOptions(options: SerializableOptions): AzureOpenAIResponsesOptions {
	return {
		...commonRuntimeOptions(options),
		...(options.azureApiVersion ? { azureApiVersion: options.azureApiVersion } : {}),
		...(options.azureBaseUrl ? { azureBaseUrl: options.azureBaseUrl } : {}),
		...(options.azureDeploymentName ? { azureDeploymentName: options.azureDeploymentName } : {}),
		...(options.azureResourceName ? { azureResourceName: options.azureResourceName } : {}),
	};
}

function toCodexRuntimeOptions(options: SerializableOptions): OpenAICodexResponsesOptions {
	return {
		...commonRuntimeOptions(options),
		...(options.reasoningSummary === "off" || options.reasoningSummary === "on" ? { reasoningSummary: options.reasoningSummary } : {}),
		...(options.textVerbosity ? { textVerbosity: options.textVerbosity } : {}),
		...(options.transport ? { transport: options.transport } : {}),
	};
}

function normalizeHeaders(headers: Headers): Record<string, string> {
	const semanticHeaders: Record<string, string> = {};
	for (const [rawName, rawValue] of headers.entries()) {
		const name = rawName.toLowerCase();
		if (name === "authorization" || name === "api-key") {
			semanticHeaders[name] = rawValue.length > 0 ? "<redacted-present>" : "<redacted-empty>";
		} else if (
			name === "accept" ||
			name === "chatgpt-account-id" ||
			name === "content-type" ||
			name === "copilot-integration-id" ||
			name === "copilot-vision-request" ||
			name === "editor-plugin-version" ||
			name === "editor-version" ||
			name === "openai-beta" ||
			name === "openai-intent" ||
			name === "originator" ||
			name === "session_id" ||
			(name === "user-agent" && rawValue.startsWith("GitHubCopilotChat/")) ||
			name === "x-client-request-id" ||
			name === "x-initiator" ||
			name.startsWith("x-fixture-")
		) {
			semanticHeaders[name] = rawValue;
		}
	}
	return stableValue(semanticHeaders) as Record<string, string>;
}

function queryRecord(url: URL): Record<string, string> {
	const output: Record<string, string> = {};
	for (const [key, value] of url.searchParams.entries()) output[key] = value;
	return stableValue(output) as Record<string, string>;
}

function inferBaseUrl(url: URL, providerFamily: ProviderFamily): string {
	const suffix = providerFamily === "openai-codex" ? "/codex/responses" : "/responses";
	const path = url.pathname.endsWith(suffix) ? url.pathname.slice(0, -suffix.length) : url.pathname;
	return `${url.origin}${path}`;
}

async function requestBody(request: Request): Promise<unknown> {
	const text = await request.text();
	return text.length > 0 ? (JSON.parse(text) as unknown) : null;
}

function buildMockStream(providerFamily: ProviderFamily): ReadableStream<Uint8Array> {
	const encoder = new TextEncoder();
	return new ReadableStream<Uint8Array>({
		start(controller) {
			const terminalType = providerFamily === "openai-codex" ? "response.completed" : "response.completed";
			const chunks: unknown[] = [
				{ type: "response.created", response: { id: `resp_${providerFamily.replace(/-/g, "_")}` } },
				{
					type: "response.output_item.added",
					item: { type: "message", id: "msg_fixture", role: "assistant", status: "in_progress", content: [] },
				},
				{ type: "response.content_part.added", part: { type: "output_text", text: "" } },
				{ type: "response.output_text.delta", delta: "fixture" },
				{
					type: "response.output_item.done",
					item: {
						type: "message",
						id: "msg_fixture",
						role: "assistant",
						status: "completed",
						content: [{ type: "output_text", text: "fixture", annotations: [] }],
					},
				},
				{
					type: terminalType,
					response: {
						id: `resp_${providerFamily.replace(/-/g, "_")}`,
						status: "completed",
						usage: { input_tokens: 7, output_tokens: 5, total_tokens: 12, input_tokens_details: { cached_tokens: 0 } },
					},
				},
			];
			for (const chunk of chunks) controller.enqueue(encoder.encode(`data: ${JSON.stringify(chunk)}\n\n`));
			controller.enqueue(encoder.encode("data: [DONE]\n\n"));
			controller.close();
		},
	});
}

async function captureScenario(scenario: Scenario): Promise<FixtureRecord> {
	const originalFetch = globalThis.fetch;
	const originalEnv = saveCredentialEnv();
	const allowedHosts = new Set<string>([
		new URL(scenario.input.model.baseUrl || "https://chatgpt.com/backend-api").host,
		"api.openai.com",
		"chatgpt.com",
		"fixture-resource-override.openai.azure.com",
		"fixture-resource.openai.azure.com",
	]);
	let capturedFetch: CapturedFetch | undefined;
	let observedPayload: unknown;

	applySentinelCredentialEnv();

	globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
		const request = input instanceof Request ? input : new Request(input, init);
		const requestUrl = new URL(request.url);
		if (!allowedHosts.has(requestUrl.host)) {
			throw new Error(`Blocked unmocked Responses fixture network egress: ${request.url}`);
		}
		capturedFetch = {
			request: {
				method: request.method,
				url: `${requestUrl.origin}${requestUrl.pathname}${requestUrl.search}`,
				baseUrl: inferBaseUrl(requestUrl, scenario.providerFamily),
				path: requestUrl.pathname,
				query: queryRecord(requestUrl),
				headers: normalizeHeaders(request.headers),
				jsonPayload: await requestBody(request),
				requestOptions: {
					...(scenario.input.options.timeoutMs !== undefined ? { timeoutMs: scenario.input.options.timeoutMs } : {}),
					...(scenario.input.options.maxRetries !== undefined ? { maxRetries: scenario.input.options.maxRetries } : {}),
					signal: "not-provided",
				},
				transportMetadata: {
					mode: "sse",
					mockedStatus: 200,
					mockedResponseHeaders: { "content-type": "text/event-stream", "x-fixture-response": scenario.id },
					providerFamily: scenario.providerFamily,
					requestBoundary: "before local mocked SSE response body is consumed",
				},
			},
		};
		return new Response(buildMockStream(scenario.providerFamily), {
			status: 200,
			headers: capturedFetch.request.transportMetadata.mockedResponseHeaders,
		});
	};

	try {
		const stream = runScenarioStream(scenario, (payload) => {
			observedPayload = payload;
			if (scenario.input.options.onPayload === "replace-with-fixture-payload") return scenario.input.options.payloadReplacement;
			return undefined;
		});
		const events: AssistantMessageEvent[] = [];
		for await (const event of stream) events.push(event);
		const terminalEvent = events.at(-1);
		if (terminalEvent?.type !== "done") {
			throw new Error(`Scenario ${scenario.id} did not complete with a done event`);
		}
		if (!capturedFetch) throw new Error(`Scenario ${scenario.id} did not capture a Responses request`);

		return {
			schemaVersion,
			id: scenario.id,
			title: scenario.title,
			providerFamily: scenario.providerFamily,
			input: scenario.input,
			expected: {
				typeScriptRequest: capturedFetch.request,
				...(scenario.input.options.onPayload
					? {
							onPayload: {
								observedPayload,
								...(scenario.input.options.payloadReplacement === undefined ? {} : { replacementPayload: scenario.input.options.payloadReplacement }),
							},
						}
					: {}),
			},
			metadata: {
				captureBoundary:
					"Responses-family request after model/options resolution, payload conversion, header merge, callbacks, and before live HTTP/WebSocket transport",
				captureMethod:
					"global fetch is replaced with a deterministic local mock that records final request semantics and rejects unhandled hosts",
				diffOutputBoundBytes: 12_000,
				network: "global fetch mock rejects unhandled requests",
				sourceCitations,
			},
		};
	} finally {
		globalThis.fetch = originalFetch;
		restoreCredentialEnv(originalEnv);
	}
}

function runScenarioStream(scenario: Scenario, onPayload: (payload: unknown) => unknown) {
	if (scenario.providerFamily === "azure-openai") {
		const options = toAzureRuntimeOptions(scenario.input.options);
		if (scenario.input.options.onPayload) options.onPayload = (payload) => onPayload(payload);
		return streamAzureOpenAIResponses(
			toRuntimeModel<"azure-openai-responses">(scenario.input.model),
			toRuntimeContext(scenario.input.context),
			options,
		);
	}
	if (scenario.providerFamily === "openai-codex") {
		const options = toCodexRuntimeOptions(scenario.input.options);
		if (scenario.input.options.onPayload) options.onPayload = (payload) => onPayload(payload);
		return streamOpenAICodexResponses(
			toRuntimeModel<"openai-codex-responses">(scenario.input.model),
			toRuntimeContext(scenario.input.context),
			options,
		);
	}
	const options = commonRuntimeOptions(scenario.input.options);
	if (scenario.input.options.onPayload) options.onPayload = (payload) => onPayload(payload);
	return streamOpenAIResponses(
		toRuntimeModel<"openai-responses">(scenario.input.model),
		toRuntimeContext(scenario.input.context),
		options,
	);
}

function saveCredentialEnv(): Record<string, string | undefined> {
	return {
		AZURE_OPENAI_API_KEY: process.env.AZURE_OPENAI_API_KEY,
		AZURE_OPENAI_API_VERSION: process.env.AZURE_OPENAI_API_VERSION,
		AZURE_OPENAI_BASE_URL: process.env.AZURE_OPENAI_BASE_URL,
		AZURE_OPENAI_DEPLOYMENT_NAME_MAP: process.env.AZURE_OPENAI_DEPLOYMENT_NAME_MAP,
		AZURE_OPENAI_RESOURCE_NAME: process.env.AZURE_OPENAI_RESOURCE_NAME,
		COPILOT_GITHUB_TOKEN: process.env.COPILOT_GITHUB_TOKEN,
		GH_TOKEN: process.env.GH_TOKEN,
		GITHUB_TOKEN: process.env.GITHUB_TOKEN,
		OPENAI_API_KEY: process.env.OPENAI_API_KEY,
		PI_CACHE_RETENTION: process.env.PI_CACHE_RETENTION,
	};
}

function applySentinelCredentialEnv(): void {
	process.env.AZURE_OPENAI_API_KEY = "fixture-env-sentinel-not-read";
	delete process.env.AZURE_OPENAI_API_VERSION;
	delete process.env.AZURE_OPENAI_BASE_URL;
	delete process.env.AZURE_OPENAI_DEPLOYMENT_NAME_MAP;
	delete process.env.AZURE_OPENAI_RESOURCE_NAME;
	process.env.COPILOT_GITHUB_TOKEN = "fixture-env-sentinel-not-read";
	process.env.GH_TOKEN = "fixture-env-sentinel-not-read";
	process.env.GITHUB_TOKEN = "fixture-env-sentinel-not-read";
	process.env.OPENAI_API_KEY = "fixture-env-sentinel-not-read";
	delete process.env.PI_CACHE_RETENTION;
}

function restoreCredentialEnv(env: Record<string, string | undefined>): void {
	for (const [key, value] of Object.entries(env)) {
		if (value === undefined) delete process.env[key];
		else process.env[key] = value;
	}
}

function validateNoVolatileStrings(value: unknown, path: string): void {
	if (typeof value === "string") {
		if (value.length > maxStringLength) throw new Error(`${path} exceeds ${maxStringLength} characters`);
		const forbidden = [repoRoot, scriptDir, "/Users/", "file://", "Bearer ", "sk-", fakeCodexJwt, "darwin ", "linux ", "win32 ", "OpenAI/JS", "AzureOpenAI/JS"];
		for (const marker of forbidden) {
			if (value.includes(marker)) throw new Error(`${path} contains volatile or secret-like marker ${JSON.stringify(marker)}`);
		}
		if (/\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(value)) {
			throw new Error(`${path} contains timestamp-like value`);
		}
		return;
	}
	if (Array.isArray(value)) {
		value.forEach((item, index) => validateNoVolatileStrings(item, `${path}[${index}]`));
		return;
	}
	if (value && typeof value === "object") {
		for (const [key, child] of Object.entries(value)) {
			if (["created", "pid", "socket", "timestamp", "wallClockMs"].includes(key)) {
				throw new Error(`${path}.${key} contains volatile field ${key}`);
			}
			validateNoVolatileStrings(child, `${path}.${key}`);
		}
	}
}

function validateFixture(record: FixtureRecord): void {
	const allowedTopLevelKeys = ["expected", "id", "input", "metadata", "providerFamily", "schemaVersion", "title"];
	for (const key of Object.keys(record)) {
		if (!allowedTopLevelKeys.includes(key)) throw new Error(`Fixture ${record.id} contains unknown top-level key ${key}`);
	}
	if (record.schemaVersion !== schemaVersion) throw new Error(`Fixture ${record.id} has unsupported schemaVersion ${String(record.schemaVersion)}`);
	if (!record.input || !record.expected?.typeScriptRequest) {
		throw new Error(`Fixture ${record.id} must include input and expected.typeScriptRequest`);
	}
	if (!requiredCategories.includes(record.providerFamily)) throw new Error(`Fixture ${record.id} has unsupported providerFamily`);
	if (!record.id || !/^[a-z0-9][a-z0-9-]*$/.test(record.id)) throw new Error(`Fixture ${record.id} must have a stable kebab-case id`);
	const request = record.expected.typeScriptRequest;
	if (request.method !== "POST") throw new Error(`Fixture ${record.id} must capture POST method`);
	if (!request.url || !request.path || !request.baseUrl) throw new Error(`Fixture ${record.id} must capture URL/baseUrl/path`);
	if (!request.headers || !request.jsonPayload || !request.requestOptions || !request.transportMetadata) {
		throw new Error(`Fixture ${record.id} must capture headers, JSON payload, request options, and transport metadata`);
	}
	const serialized = stableStringify(record);
	if (Buffer.byteLength(serialized) > maxFixtureBytes) throw new Error(`Fixture ${record.id} exceeds ${maxFixtureBytes} bytes`);
	validateNoVolatileStrings(record, record.id);
}

function validateRecords(records: FixtureRecord[]): void {
	const ids = new Set<string>();
	const categories = new Set<ProviderFamily>();
	for (const record of records) {
		if (ids.has(record.id)) throw new Error(`Duplicate OpenAI Responses fixture id ${record.id}`);
		ids.add(record.id);
		categories.add(record.providerFamily);
		validateFixture(record);
	}
	for (const category of requiredCategories) {
		if (!categories.has(category)) throw new Error(`Missing required OpenAI Responses fixture category ${category}`);
	}
}

function runSchemaNegativeSelfTests(records: FixtureRecord[]): void {
	const first = records[0];
	const negativeCases: [string, FixtureRecord[]][] = [
		["missing/unknown schema version", [{ ...first, schemaVersion: 999 as typeof schemaVersion }]],
		["duplicate scenario id", [first, { ...records[1], id: first.id }]],
		["missing input section", [{ ...first, input: undefined as unknown as ScenarioInput }]],
		["volatile field", [{ ...first, metadata: { ...first.metadata, pid: 123 } as unknown as FixtureRecord["metadata"] }]],
		["secret-like value", [{ ...first, title: "contains sk-secret-for-negative-test" }]],
		["oversized value", [{ ...first, title: "x".repeat(maxStringLength + 1) }]],
	];
	for (const [name, candidate] of negativeCases) {
		let failed = false;
		try {
			validateRecords(candidate);
		} catch {
			failed = true;
		}
		if (!failed) throw new Error(`Negative schema self-test did not fail: ${name}`);
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
		generatedBy: "zig/test/generate-openai-responses-fixtures.ts",
		fixtureCount: records.length,
		scenarioIds: records.map((record) => record.id),
		providerFamilies: requiredCategories,
		captureBoundary: "TypeScript Responses-family request after final payload/header/options resolution and before live transport",
		diffOutputBoundBytes: 12_000,
		network: "local mocked global fetch only; unhandled requests throw",
		sourceCitations,
	};
}

async function buildRecords(): Promise<FixtureRecord[]> {
	const records: FixtureRecord[] = [];
	for (const scenario of scenarios) records.push(await captureScenario(scenario));
	validateRecords(records);
	runSchemaNegativeSelfTests(records);
	return records;
}

function firstDiffPath(expected: unknown, actual: unknown, path = ""): string | undefined {
	if (Object.is(expected, actual)) return undefined;
	if (Array.isArray(expected) || Array.isArray(actual)) {
		if (!Array.isArray(expected) || !Array.isArray(actual)) return path || "<root>";
		if (expected.length !== actual.length) return path ? `${path}.length` : "length";
		for (let index = 0; index < expected.length; index++) {
			const child = firstDiffPath(expected[index], actual[index], `${path}[${index}]`);
			if (child) return child;
		}
		return undefined;
	}
	if (expected && actual && typeof expected === "object" && typeof actual === "object") {
		const expectedRecord = expected as Record<string, unknown>;
		const actualRecord = actual as Record<string, unknown>;
		const keys = Array.from(new Set([...Object.keys(expectedRecord), ...Object.keys(actualRecord)])).sort();
		for (const key of keys) {
			if (!(key in expectedRecord) || !(key in actualRecord)) return path ? `${path}.${key}` : key;
			const child = firstDiffPath(expectedRecord[key], actualRecord[key], path ? `${path}.${key}` : key);
			if (child) return child;
		}
		return undefined;
	}
	return path || "<root>";
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
		const currentRecord = readCurrentFixture(path);
		validateFixture(currentRecord);
		if (current !== next) {
			const diffPath = firstDiffPath(stableValue(record), stableValue(currentRecord)) || "bytes";
			errors.push(`Fixture drift for ${record.id} at ${diffPath}: ${relative(scriptDir, path)}`);
		}
	}

	const manifest = stableStringify(buildManifest(records));
	if (!existsSync(manifestPath())) {
		errors.push(`Missing OpenAI Responses manifest: ${relative(scriptDir, manifestPath())}`);
	} else if (readFileSync(manifestPath(), "utf8") !== manifest) {
		errors.push(`Fixture drift for manifest at ${firstDiffPath(stableValue(buildManifest(records)), JSON.parse(readFileSync(manifestPath(), "utf8")) as unknown) || "bytes"}: ${relative(scriptDir, manifestPath())}`);
	}

	if (existsSync(fixtureDir)) {
		for (const file of readdirSync(fixtureDir)) {
			if (file.endsWith(".json") && !expectedFiles.has(file)) {
				errors.push(`Unexpected OpenAI Responses fixture file: ${relative(scriptDir, join(fixtureDir, file))}`);
			}
		}
	}

	if (errors.length > 0) {
		throw new Error(
			`OpenAI Responses fixtures are stale. Run \`npx tsx test/generate-openai-responses-fixtures.ts\`.\n${errors.join("\n")}`,
		);
	}
}

function writeFiles(records: FixtureRecord[]): void {
	mkdirSync(fixtureDir, { recursive: true });
	for (const record of records) writeFileSync(fixturePath(record.id), stableStringify(record));
	writeFileSync(manifestPath(), stableStringify(buildManifest(records)));
}

async function main(): Promise<void> {
	const records = await buildRecords();
	if (checkMode) {
		checkFiles(records);
		console.log(`OpenAI Responses fixtures are up to date (${records.length} scenarios)`);
	} else {
		writeFiles(records);
		console.log(`Wrote ${records.length} OpenAI Responses fixtures to ${relative(process.cwd(), fixtureDir)}`);
	}
}

main().catch((error: unknown) => {
	const message = error instanceof Error ? error.message : String(error);
	console.error(message);
	process.exitCode = 1;
});
