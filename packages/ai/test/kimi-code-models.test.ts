import { afterEach, describe, expect, test, vi } from "vitest";
import { findEnvKeys, getEnvApiKey } from "../src/env-api-keys.js";
import { getModel, getModels } from "../src/models.js";
import { streamSimple } from "../src/stream.js";

interface FakeOpenAIClientOptions {
	apiKey: string;
	baseURL: string;
	dangerouslyAllowBrowser: boolean;
	defaultHeaders?: Record<string, string>;
}

interface CapturedCompletionsPayload {
	model: string;
	max_tokens?: number;
	max_completion_tokens?: number;
	reasoning_effort?: string;
	store?: boolean;
	stream_options?: { include_usage?: boolean };
}

const originalKimiApiKey = process.env.KIMI_API_KEY;
const mockState = vi.hoisted(() => ({
	lastParams: undefined as CapturedCompletionsPayload | undefined,
	lastClientOptions: undefined as FakeOpenAIClientOptions | undefined,
}));

vi.mock("openai", () => {
	class FakeOpenAI {
		chat = {
			completions: {
				create: (params: CapturedCompletionsPayload) => {
					mockState.lastParams = params;
					const fakeStream = {
						async *[Symbol.asyncIterator]() {
							yield {
								id: "chatcmpl-test",
								model: "kimi-for-coding",
								choices: [{ delta: { content: "ok" }, finish_reason: null }],
							};
							yield {
								id: "chatcmpl-test",
								model: "kimi-for-coding",
								choices: [{ delta: {}, finish_reason: "stop" }],
								usage: {
									prompt_tokens: 1,
									completion_tokens: 1,
									prompt_tokens_details: { cached_tokens: 0 },
									completion_tokens_details: { reasoning_tokens: 0 },
								},
							};
						},
					};
					const promise = Promise.resolve(fakeStream) as Promise<typeof fakeStream> & {
						withResponse: () => Promise<{
							data: typeof fakeStream;
							response: { status: number; headers: Headers };
						}>;
					};
					promise.withResponse = async () => ({
						data: fakeStream,
						response: { status: 200, headers: new Headers() },
					});
					return promise;
				},
			},
		};

		constructor(options: FakeOpenAIClientOptions) {
			mockState.lastClientOptions = options;
		}
	}

	return { default: FakeOpenAI };
});

afterEach(() => {
	mockState.lastParams = undefined;
	mockState.lastClientOptions = undefined;
	if (originalKimiApiKey === undefined) {
		delete process.env.KIMI_API_KEY;
	} else {
		process.env.KIMI_API_KEY = originalKimiApiKey;
	}
});

describe("Kimi Code model catalog", () => {
	test("uses the canonical Anthropic-compatible Kimi Code model without spoofed headers", () => {
		const models = getModels("kimi-coding");

		expect(models.map((model) => model.id)).toEqual(["kimi-for-coding"]);
		expect(models[0]).toMatchObject({
			api: "anthropic-messages",
			provider: "kimi-coding",
			baseUrl: "https://api.kimi.com/coding",
		});
		expect(models[0].headers?.["User-Agent"]).toBeUndefined();
	});

	test("registers OpenAI-compatible Kimi Code with the canonical model and KIMI_API_KEY", () => {
		process.env.KIMI_API_KEY = "test-kimi-key";
		const model = getModel("kimi-code-openai", "kimi-for-coding");

		expect(model).toMatchObject({
			api: "openai-completions",
			provider: "kimi-code-openai",
			baseUrl: "https://api.kimi.com/coding/v1",
			compat: {
				supportsStore: false,
				supportsDeveloperRole: false,
				supportsReasoningEffort: false,
				maxTokensField: "max_tokens",
				supportsStrictMode: false,
			},
		});
		expect(model.headers?.["User-Agent"]).toBeUndefined();
		expect(findEnvKeys("kimi-code-openai")).toEqual(["KIMI_API_KEY"]);
		expect(getEnvApiKey("kimi-code-openai")).toBe("test-kimi-key");
	});

	test("routes OpenAI-compatible Kimi Code through the OpenAI completions provider", async () => {
		process.env.KIMI_API_KEY = "test-kimi-key";
		const model = getModel("kimi-code-openai", "kimi-for-coding");

		const result = await streamSimple(
			model,
			{
				messages: [{ role: "user", content: "hi", timestamp: Date.now() }],
			},
			{ maxTokens: 32, reasoning: "high" },
		).result();

		expect(result).toMatchObject({
			api: "openai-completions",
			provider: "kimi-code-openai",
			model: "kimi-for-coding",
			stopReason: "stop",
		});
		expect(result.content).toEqual([{ type: "text", text: "ok" }]);
		expect(mockState.lastClientOptions).toMatchObject({
			apiKey: "test-kimi-key",
			baseURL: "https://api.kimi.com/coding/v1",
			dangerouslyAllowBrowser: true,
		});
		expect(mockState.lastClientOptions?.defaultHeaders?.["User-Agent"]).toBeUndefined();
		expect(mockState.lastParams).toMatchObject({
			model: "kimi-for-coding",
			max_tokens: 32,
			stream_options: { include_usage: true },
		});
		expect(mockState.lastParams?.max_completion_tokens).toBeUndefined();
		expect(mockState.lastParams?.reasoning_effort).toBeUndefined();
		expect(mockState.lastParams?.store).toBeUndefined();
	});
});
