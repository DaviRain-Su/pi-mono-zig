/**
 * xAI Grok OAuth flow for SuperGrok subscriptions.
 *
 * NOTE: This module uses Node.js crypto and http for the OAuth callback.
 * It is only intended for CLI use, not browser environments.
 */
import { randomBytes } from "node:crypto";
import { createServer } from "node:http";
import { oauthErrorHtml, oauthSuccessHtml } from "./oauth-page.js";
import { generatePKCE } from "./pkce.js";
const DISCOVERY_URL = "https://auth.x.ai/.well-known/openid-configuration";
const CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828";
const SCOPE = "openid profile email offline_access grok-cli:access api:access";
const CALLBACK_HOST = process.env.PI_OAUTH_CALLBACK_HOST || "127.0.0.1";
const CALLBACK_PORT = 56121;
const CALLBACK_PATH = "/callback";
const REDIRECT_URI = `http://127.0.0.1:${CALLBACK_PORT}${CALLBACK_PATH}`;
const REFRESH_SKEW_MS = 120_000;
function createState() {
    return randomBytes(16).toString("hex");
}
function createNonce() {
    return randomBytes(16).toString("hex");
}
function parseAuthorizationInput(input) {
    const value = input.trim();
    if (!value)
        return {};
    try {
        const url = new URL(value);
        return {
            code: url.searchParams.get("code") ?? undefined,
            state: url.searchParams.get("state") ?? undefined,
        };
    }
    catch {
        // not a URL
    }
    if (value.includes("#")) {
        const [code, state] = value.split("#", 2);
        return { code, state };
    }
    if (value.includes("code=")) {
        const params = new URLSearchParams(value);
        return {
            code: params.get("code") ?? undefined,
            state: params.get("state") ?? undefined,
        };
    }
    return { code: value };
}
async function getDiscoveryDocument() {
    const response = await fetch(DISCOVERY_URL, {
        headers: { Accept: "application/json" },
        signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) {
        const text = await response.text().catch(() => "");
        throw new Error(`xAI OAuth discovery failed (${response.status}): ${text || response.statusText}`);
    }
    const data = (await response.json());
    if (!data.authorization_endpoint || !data.token_endpoint) {
        throw new Error(`xAI OAuth discovery response missing endpoints: ${JSON.stringify(data)}`);
    }
    return {
        authorization_endpoint: data.authorization_endpoint,
        token_endpoint: data.token_endpoint,
    };
}
function startCallbackServer(expectedState) {
    let settleWait;
    const waitForCodePromise = new Promise((resolve) => {
        let settled = false;
        settleWait = (value) => {
            if (settled)
                return;
            settled = true;
            resolve(value);
        };
    });
    const server = createServer((req, res) => {
        try {
            const origin = req.headers.origin;
            const allowOrigin = origin === "https://accounts.x.ai" || origin === "https://auth.x.ai" ? origin : undefined;
            const writeCorsHeaders = () => {
                if (!allowOrigin)
                    return;
                res.setHeader("Access-Control-Allow-Origin", allowOrigin);
                res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
                res.setHeader("Access-Control-Allow-Headers", "Content-Type");
                res.setHeader("Access-Control-Allow-Private-Network", "true");
                res.setHeader("Vary", "Origin");
            };
            if (req.method === "OPTIONS") {
                res.statusCode = 204;
                writeCorsHeaders();
                res.end();
                return;
            }
            const url = new URL(req.url || "", "http://localhost");
            if (url.pathname !== CALLBACK_PATH) {
                res.statusCode = 404;
                writeCorsHeaders();
                res.setHeader("Content-Type", "text/html; charset=utf-8");
                res.end(oauthErrorHtml("Callback route not found."));
                return;
            }
            const code = url.searchParams.get("code");
            const state = url.searchParams.get("state");
            const error = url.searchParams.get("error");
            if (error) {
                res.statusCode = 400;
                writeCorsHeaders();
                res.setHeader("Content-Type", "text/html; charset=utf-8");
                res.end(oauthErrorHtml("xAI authentication did not complete.", `Error: ${error}`));
                return;
            }
            if (!code || !state) {
                res.statusCode = 400;
                writeCorsHeaders();
                res.setHeader("Content-Type", "text/html; charset=utf-8");
                res.end(oauthErrorHtml("Missing code or state parameter."));
                return;
            }
            if (state !== expectedState) {
                res.statusCode = 400;
                writeCorsHeaders();
                res.setHeader("Content-Type", "text/html; charset=utf-8");
                res.end(oauthErrorHtml("State mismatch."));
                return;
            }
            res.statusCode = 200;
            writeCorsHeaders();
            res.setHeader("Content-Type", "text/html; charset=utf-8");
            res.end(oauthSuccessHtml("xAI authentication completed. You can close this window."));
            settleWait?.({ code, state });
        }
        catch {
            res.statusCode = 500;
            res.setHeader("Content-Type", "text/html; charset=utf-8");
            res.end(oauthErrorHtml("Internal error while processing OAuth callback."));
        }
    });
    return new Promise((resolve) => {
        server
            .listen(CALLBACK_PORT, CALLBACK_HOST, () => {
            resolve({
                close: () => {
                    try {
                        server.close();
                    }
                    catch {
                        // ignore
                    }
                },
                cancelWait: () => settleWait?.(null),
                waitForCode: () => waitForCodePromise,
            });
        })
            .on("error", () => {
            settleWait?.(null);
            resolve({
                close: () => {
                    try {
                        server.close();
                    }
                    catch {
                        // ignore
                    }
                },
                cancelWait: () => { },
                waitForCode: async () => null,
            });
        });
    });
}
function buildAuthorizeUrl(authorizationEndpoint, state, nonce, challenge) {
    const url = new URL(authorizationEndpoint);
    url.searchParams.set("response_type", "code");
    url.searchParams.set("client_id", CLIENT_ID);
    url.searchParams.set("redirect_uri", REDIRECT_URI);
    url.searchParams.set("scope", SCOPE);
    url.searchParams.set("code_challenge", challenge);
    url.searchParams.set("code_challenge_method", "S256");
    url.searchParams.set("state", state);
    url.searchParams.set("nonce", nonce);
    url.searchParams.set("plan", "generic");
    url.searchParams.set("referrer", "hermes-agent");
    return url.toString();
}
async function postTokenRequest(tokenEndpoint, body, action) {
    const response = await fetch(tokenEndpoint, {
        method: "POST",
        headers: {
            "Content-Type": "application/x-www-form-urlencoded",
            Accept: "application/json",
        },
        body: new URLSearchParams(body),
        signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) {
        const text = await response.text().catch(() => "");
        throw new Error(`xAI OAuth token ${action} failed (${response.status}): ${text || response.statusText}`);
    }
    const json = (await response.json());
    if (!json.access_token || typeof json.expires_in !== "number") {
        throw new Error(`xAI OAuth token ${action} response missing fields: ${JSON.stringify(json)}`);
    }
    const refresh = json.refresh_token ?? body.refresh_token;
    if (!refresh) {
        throw new Error(`xAI OAuth token ${action} response missing refresh_token`);
    }
    return {
        access: json.access_token,
        refresh,
        expires: Date.now() + json.expires_in * 1000 - REFRESH_SKEW_MS,
    };
}
async function exchangeAuthorizationCode(code, verifier, tokenEndpoint) {
    return postTokenRequest(tokenEndpoint, {
        grant_type: "authorization_code",
        client_id: CLIENT_ID,
        code,
        code_verifier: verifier,
        redirect_uri: REDIRECT_URI,
    }, "exchange");
}
/**
 * Login with xAI Grok OAuth.
 */
export async function loginXAI(options) {
    const discovery = await getDiscoveryDocument();
    const { verifier, challenge } = await generatePKCE();
    const state = createState();
    const nonce = createNonce();
    const server = await startCallbackServer(state);
    try {
        options.onAuth({
            url: buildAuthorizeUrl(discovery.authorization_endpoint, state, nonce, challenge),
            instructions: "Complete login in your browser. If the browser is on another machine, paste the final redirect URL here.",
        });
        let code;
        if (options.onManualCodeInput) {
            let manualInput;
            let manualError;
            const manualPromise = options
                .onManualCodeInput()
                .then((input) => {
                manualInput = input;
                server.cancelWait();
            })
                .catch((error) => {
                manualError = error instanceof Error ? error : new Error(String(error));
                server.cancelWait();
            });
            const result = await server.waitForCode();
            if (manualError)
                throw manualError;
            if (result?.code) {
                code = result.code;
            }
            else if (manualInput) {
                const parsed = parseAuthorizationInput(manualInput);
                if (parsed.state && parsed.state !== state)
                    throw new Error("State mismatch");
                code = parsed.code;
            }
            if (!code) {
                await manualPromise;
                if (manualError)
                    throw manualError;
                if (manualInput) {
                    const parsed = parseAuthorizationInput(manualInput);
                    if (parsed.state && parsed.state !== state)
                        throw new Error("State mismatch");
                    code = parsed.code;
                }
            }
        }
        else {
            const result = await server.waitForCode();
            code = result?.code;
        }
        if (!code) {
            const input = await options.onPrompt({
                message: "Paste the authorization code or full redirect URL:",
                placeholder: REDIRECT_URI,
            });
            const parsed = parseAuthorizationInput(input);
            if (parsed.state && parsed.state !== state)
                throw new Error("State mismatch");
            code = parsed.code;
        }
        if (!code) {
            throw new Error("Missing authorization code");
        }
        options.onProgress?.("Exchanging authorization code for tokens...");
        return exchangeAuthorizationCode(code, verifier, discovery.token_endpoint);
    }
    finally {
        server.close();
    }
}
/**
 * Refresh xAI Grok OAuth token.
 */
export async function refreshXAIToken(refreshToken) {
    const discovery = await getDiscoveryDocument();
    return postTokenRequest(discovery.token_endpoint, {
        grant_type: "refresh_token",
        refresh_token: refreshToken,
        client_id: CLIENT_ID,
    }, "refresh");
}
export const xaiOAuthProvider = {
    id: "xai-oauth",
    name: "xAI Grok OAuth (SuperGrok Subscription)",
    usesCallbackServer: true,
    async login(callbacks) {
        return loginXAI({
            onAuth: callbacks.onAuth,
            onPrompt: callbacks.onPrompt,
            onProgress: callbacks.onProgress,
            onManualCodeInput: callbacks.onManualCodeInput,
        });
    },
    async refreshToken(credentials) {
        return refreshXAIToken(credentials.refresh);
    },
    getApiKey(credentials) {
        return credentials.access;
    },
};
//# sourceMappingURL=xai.js.map