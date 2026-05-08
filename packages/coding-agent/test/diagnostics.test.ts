import { describe, expect, it } from "vitest";
import {
	adaptExtensionErrorToDiagnosticEnvelope,
	adaptResourceDiagnosticToEnvelope,
	createDiagnosticEnvelope,
	redactDiagnosticValue,
} from "../src/core/diagnostics.js";

function joinSensitiveParts(parts: readonly string[]): string {
	return parts.join("");
}

function diagnosticCredential(label: string): string {
	return joinSensitiveParts(["s", "k", "-", label, "-diagnostic-value"]);
}

function diagnosticBearer(label: string): string {
	return ["Bearer", diagnosticCredential(label)].join(" ");
}

function diagnosticQueryUrl(queryKey: string, value: string, pathname = "/v1"): string {
	const url = new URL("https://api.example.test");
	url.pathname = pathname;
	url.searchParams.set(queryKey, value);
	return url.toString();
}

describe("diagnostic envelopes", () => {
	it("adapts legacy resource diagnostics into canonical v0 envelopes", () => {
		const envelope = adaptResourceDiagnosticToEnvelope(
			{
				type: "collision",
				message: "name collision between resources",
				path: "/repo/.pi/skills/web/SKILL.md",
				collision: {
					resourceType: "skill",
					name: "web",
					winnerPath: "/repo/.pi/skills/web/SKILL.md",
					loserPath: "/repo/pkg/skills/web/SKILL.md",
					winnerSource: "local",
					loserSource: "npm:pkg",
				},
			},
			{ phase: "load", runtimeKind: "typescript", extensionIdentity: "typescript:package:project:pkg" },
		);

		expect(envelope).toEqual({
			schemaVersion: "diagnostic-envelope.v0",
			severity: "warning",
			phase: "load",
			runtimeKind: "typescript",
			category: "resource_collision",
			message: "name collision between resources",
			recoveryHint: "Rename or remove one of the colliding resources.",
			source: { path: "/repo/.pi/skills/web/SKILL.md" },
			extensionIdentity: "typescript:package:project:pkg",
			path: "/repo/.pi/skills/web/SKILL.md",
			details: {
				collision: {
					loserPath: "/repo/pkg/skills/web/SKILL.md",
					loserSource: "npm:pkg",
					name: "web",
					resourceType: "skill",
					winnerPath: "/repo/.pi/skills/web/SKILL.md",
					winnerSource: "local",
				},
			},
		});
	});

	it("adapts extension runtime errors with attribution and redacted secret details", () => {
		const apiKeyValue = diagnosticCredential("provider");
		const queryValue = joinSensitiveParts(["query", "-diagnostic", "-value"]);
		const oauthValue = joinSensitiveParts(["oauth", "-access", "-value"]);
		const providerHeaderValue = joinSensitiveParts(["provider", "-header", "-value"]);
		const envelope = adaptExtensionErrorToDiagnosticEnvelope({
			extensionPath: "/repo/.pi/extensions/provider.ts",
			event: "before_provider_request",
			error: `Authorization: ${diagnosticBearer("provider")} and ${diagnosticQueryUrl(
				joinSensitiveParts(["api", "_", "key"]),
				queryValue,
			)}`,
			phase: "event",
			runtimeKind: "typescript",
			category: "provider_request_failed",
			capability: "model.call",
			operation: "provider.headers",
			target: {
				headers: {
					Authorization: ["Bearer", oauthValue].join(" "),
					"x-api-key": providerHeaderValue,
					"anthropic-version": "2023-06-01",
				},
			},
			extensionIdentity: "typescript:local:project:/repo/.pi/extensions/provider.ts",
		});

		expect(envelope).toMatchObject({
			schemaVersion: "diagnostic-envelope.v0",
			severity: "error",
			phase: "event",
			runtimeKind: "typescript",
			category: "provider_request_failed",
			source: { path: "/repo/.pi/extensions/provider.ts" },
			extensionIdentity: "typescript:local:project:/repo/.pi/extensions/provider.ts",
			event: "before_provider_request",
			capability: "model.call",
			operation: "provider.headers",
			target: {
				headers: {
					Authorization: "[REDACTED]",
					"x-api-key": "[REDACTED]",
					"anthropic-version": "2023-06-01",
				},
			},
		});
		const serializedEnvelope = JSON.stringify(envelope);
		expect(serializedEnvelope).not.toContain(apiKeyValue);
		expect(serializedEnvelope).not.toContain(queryValue);
		expect(serializedEnvelope).not.toContain(oauthValue);
		expect(serializedEnvelope).not.toContain(providerHeaderValue);
		expect(envelope.message).toContain("Authorization: [REDACTED]");
		expect(envelope.message).toContain("api_key=[REDACTED]");
	});

	it("redacts nested credential-bearing URLs, provider headers, OAuth tokens, and command/env secrets", () => {
		const envKey = joinSensitiveParts(["OPENAI", "_API", "_KEY"]);
		const accessTokenKey = joinSensitiveParts(["access", "_", "token"]);
		const oauthValue = joinSensitiveParts(["oauth", "-diagnostic", "-value"]);
		const envValue = diagnosticCredential("env");
		const commandValue = diagnosticCredential("command");
		const cliValue = joinSensitiveParts(["cli", "-diagnostic", "-value"]);
		const bearerValue = joinSensitiveParts(["bearer", "-diagnostic", "-value"]);
		const providerHeaderValue = joinSensitiveParts(["provider", "-diagnostic", "-value"]);
		const credentialUrl = new URL("https://api.example.test/path");
		credentialUrl.username = joinSensitiveParts(["diagnostic", "-user"]);
		credentialUrl.password = joinSensitiveParts(["diagnostic", "-password"]);
		credentialUrl.searchParams.set(accessTokenKey, oauthValue);
		credentialUrl.searchParams.set("safe", "value");
		const expectedCredentialUrl = new URL("https://api.example.test/path");
		expectedCredentialUrl.username = "[REDACTED]";
		expectedCredentialUrl.password = "[REDACTED]";
		expectedCredentialUrl.searchParams.set(accessTokenKey, "[REDACTED]");
		expectedCredentialUrl.searchParams.set("safe", "value");
		const expectedUrl = expectedCredentialUrl.toString().replace(/%5BREDACTED%5D/gi, "[REDACTED]");

		const redacted = redactDiagnosticValue({
			url: credentialUrl.toString(),
			env: {
				[envKey]: envValue,
				NODE_ENV: "test",
			},
			command: `${envKey}=${commandValue} npm run fixture -- --${joinSensitiveParts(["tok", "en"])}=${cliValue}`,
			headers: {
				Authorization: ["Bearer", bearerValue].join(" "),
				"X-Provider-Token": providerHeaderValue,
				"Content-Type": "application/json",
			},
		});

		expect(redacted).toEqual({
			command: `${envKey}=[REDACTED] npm run fixture -- --token=[REDACTED]`,
			env: {
				NODE_ENV: "test",
				[envKey]: "[REDACTED]",
			},
			headers: {
				Authorization: "[REDACTED]",
				"Content-Type": "application/json",
				"X-Provider-Token": "[REDACTED]",
			},
			url: expectedUrl,
		});
	});

	it("creates stable envelopes without over-redacting safe attribution", () => {
		const envelope = createDiagnosticEnvelope({
			severity: "warning",
			phase: "resolve",
			runtimeKind: "wasm",
			category: "malformed_lockfile",
			message: "Unsupported schema at $.schemaVersion",
			recoveryHint: "Run install or update for the package to refresh trusted extension provenance.",
			source: { path: "/repo/.pi/extensions.lock.json", scope: "project" },
			extensionIdentity: "wasm:manifest:pi-extension.v0:fixture:0.1.0",
			path: "$.schemaVersion",
			expected: "pi-extension-lock.v0",
			actual: "pi-extension-lock.v1",
			details: { lockfilePath: "/repo/.pi/extensions.lock.json" },
		});

		expect(envelope).toEqual({
			schemaVersion: "diagnostic-envelope.v0",
			severity: "warning",
			phase: "resolve",
			runtimeKind: "wasm",
			category: "malformed_lockfile",
			message: "Unsupported schema at $.schemaVersion",
			recoveryHint: "Run install or update for the package to refresh trusted extension provenance.",
			source: { path: "/repo/.pi/extensions.lock.json", scope: "project" },
			extensionIdentity: "wasm:manifest:pi-extension.v0:fixture:0.1.0",
			path: "$.schemaVersion",
			expected: "pi-extension-lock.v0",
			actual: "pi-extension-lock.v1",
			details: { lockfilePath: "/repo/.pi/extensions.lock.json" },
		});
	});
});
