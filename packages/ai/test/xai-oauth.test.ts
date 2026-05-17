import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { getModel } from "../src/models.js";
import { getOAuthProvider, loginXAI, refreshXAIToken } from "../src/oauth.js";

const discovery = {
	authorization_endpoint: "https://accounts.x.ai/oauth/authorize",
	token_endpoint: "https://accounts.x.ai/oauth/token",
};

function jsonResponse(body: unknown, init?: ResponseInit): Response {
	return new Response(JSON.stringify(body), {
		status: 200,
		headers: { "Content-Type": "application/json" },
		...init,
	});
}

describe("xAI OAuth provider", () => {
	beforeEach(() => {
		vi.useFakeTimers();
		vi.setSystemTime(1_000_000);
	});

	afterEach(() => {
		vi.useRealTimers();
		vi.unstubAllGlobals();
	});

	test("registers a SuperGrok OAuth provider", () => {
		const provider = getOAuthProvider("xai-oauth");
		expect(provider?.name).toBe("xAI Grok OAuth (SuperGrok Subscription)");
		expect(provider?.usesCallbackServer).toBe(true);
	});

	test("exposes Grok OAuth models through the Responses API", () => {
		const model = getModel("xai-oauth", "grok-4.3");
		expect(model.provider).toBe("xai-oauth");
		expect(model.api).toBe("openai-responses");
		expect(model.baseUrl).toBe("https://api.x.ai/v1");
		expect(model.reasoning).toBe(true);
	});

	test("refreshes OAuth credentials through xAI discovery", async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(discovery))
			.mockResolvedValueOnce(
				jsonResponse({
					access_token: "new-access-token",
					expires_in: 3600,
				}),
			);
		vi.stubGlobal("fetch", fetchMock);

		const credentials = await refreshXAIToken("old-refresh-token");

		expect(credentials).toEqual({
			access: "new-access-token",
			refresh: "old-refresh-token",
			expires: 1_000_000 + 3600 * 1000 - 120_000,
		});

		const tokenRequest = fetchMock.mock.calls[1]?.[1] as RequestInit;
		expect(tokenRequest.method).toBe("POST");
		expect(String(tokenRequest.body)).toContain("grant_type=refresh_token");
		expect(String(tokenRequest.body)).toContain("client_id=b1a00492-073a-47ea-816f-4c329264a828");
	});

	test("builds the PKCE authorization URL and exchanges a pasted code", async () => {
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(discovery))
			.mockResolvedValueOnce(
				jsonResponse({
					access_token: "access-token",
					refresh_token: "refresh-token",
					expires_in: 3600,
				}),
			);
		vi.stubGlobal("fetch", fetchMock);

		let authUrl = "";
		const credentials = await loginXAI({
			onAuth: (info) => {
				authUrl = info.url;
			},
			onPrompt: async () => "",
			onManualCodeInput: async () => "http://127.0.0.1:56121/callback?code=authorization-code",
		});

		const url = new URL(authUrl);
		expect(url.origin + url.pathname).toBe(discovery.authorization_endpoint);
		expect(url.searchParams.get("response_type")).toBe("code");
		expect(url.searchParams.get("client_id")).toBe("b1a00492-073a-47ea-816f-4c329264a828");
		expect(url.searchParams.get("redirect_uri")).toBe("http://127.0.0.1:56121/callback");
		expect(url.searchParams.get("scope")).toBe("openid profile email offline_access grok-cli:access api:access");
		expect(url.searchParams.get("code_challenge_method")).toBe("S256");
		expect(url.searchParams.get("code_challenge")).toBeTruthy();
		expect(url.searchParams.get("nonce")).toBeTruthy();
		expect(url.searchParams.get("plan")).toBe("generic");
		expect(url.searchParams.get("referrer")).toBe("hermes-agent");

		expect(credentials.access).toBe("access-token");
		expect(credentials.refresh).toBe("refresh-token");

		const tokenRequest = fetchMock.mock.calls[1]?.[1] as RequestInit;
		expect(String(tokenRequest.body)).toContain("grant_type=authorization_code");
		expect(String(tokenRequest.body)).toContain("code=authorization-code");
		expect(String(tokenRequest.body)).toContain("redirect_uri=http%3A%2F%2F127.0.0.1%3A56121%2Fcallback");
	});
});
