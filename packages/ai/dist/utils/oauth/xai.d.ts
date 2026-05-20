/**
 * xAI Grok OAuth flow for SuperGrok subscriptions.
 *
 * NOTE: This module uses Node.js crypto and http for the OAuth callback.
 * It is only intended for CLI use, not browser environments.
 */
import type { OAuthCredentials, OAuthPrompt, OAuthProviderInterface } from "./types.js";
/**
 * Login with xAI Grok OAuth.
 */
export declare function loginXAI(options: {
    onAuth: (info: {
        url: string;
        instructions?: string;
    }) => void;
    onPrompt: (prompt: OAuthPrompt) => Promise<string>;
    onProgress?: (message: string) => void;
    onManualCodeInput?: () => Promise<string>;
}): Promise<OAuthCredentials>;
/**
 * Refresh xAI Grok OAuth token.
 */
export declare function refreshXAIToken(refreshToken: string): Promise<OAuthCredentials>;
export declare const xaiOAuthProvider: OAuthProviderInterface;
//# sourceMappingURL=xai.d.ts.map