import { createServer } from "node:http";
import { createConnection } from "node:net";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import {
	BrowserWasmToolHost,
	CANONICAL_CAPABILITIES,
	DeniedCapabilityError,
	EXPECTED_PURE_TRUNCATE_ERROR,
	PURE_TRUNCATE_MANIFEST,
	SECOND_VALID_PURE_TRUNCATE_INPUT,
	VALID_FIXTURE_INPUT,
	VALID_PURE_TRUNCATE_INPUT,
	attemptRuntimeImport,
	normalizePureToolError,
	validateSecondPureTruncateOutput,
	validatePureTruncateOutput,
	validateFixtureOutput,
} from "./browser-wasm-host.js";

const readJson = async (url) => JSON.parse(await readFile(fileURLToPath(url), "utf8"));
const readBytes = async (url) => new Uint8Array(await readFile(fileURLToPath(url)));
const HARNESS_HOST = "127.0.0.1";
const HARNESS_PORTS = Array.from({ length: 10 }, (_, index) => 3120 + index);
const FIXTURE_ROOT = fileURLToPath(new URL("../", import.meta.url));
const EXECUTION_ENDPOINT_PATTERN = /\/(execute|invoke|run|tool-call)(\/|\?|$)/i;

const host = new BrowserWasmToolHost({
	baseUrl: import.meta.url,
	fetchJson: readJson,
	fetchBytes: readBytes,
});

const initEvidence = await host.initialize("../browser-tool-v0/pi-extension.json");
assertClientSideZeroImportEvidence("browser fixture", initEvidence);
const output = host.execute(VALID_FIXTURE_INPUT);
if (!validateFixtureOutput(output)) {
	throw new Error(`valid fixture output mismatch: ${JSON.stringify(output)}`);
}

const pureHost = new BrowserWasmToolHost({
	baseUrl: import.meta.url,
	fetchJson: readJson,
	fetchBytes: readBytes,
});
const pureInitEvidence = await pureHost.initialize(PURE_TRUNCATE_MANIFEST);
assertClientSideZeroImportEvidence("pure truncate fixture", pureInitEvidence);
const pureOutput = pureHost.execute(VALID_PURE_TRUNCATE_INPUT);
if (!validatePureTruncateOutput(pureOutput)) {
	throw new Error(`pure truncate output mismatch: ${JSON.stringify(pureOutput)}`);
}
const secondPureOutput = pureHost.execute(SECOND_VALID_PURE_TRUNCATE_INPUT);
if (!validateSecondPureTruncateOutput(secondPureOutput)) {
	throw new Error(`second pure truncate output mismatch: ${JSON.stringify(secondPureOutput)}`);
}
if (JSON.stringify(pureOutput) === JSON.stringify(secondPureOutput)) {
	throw new Error("pure truncate outputs did not vary across distinct valid inputs");
}
try {
	pureHost.execute([]);
	throw new Error("pure truncate malformed input unexpectedly succeeded");
} catch (error) {
	const diagnostic = normalizePureToolError(error);
	if (JSON.stringify(diagnostic) !== JSON.stringify(EXPECTED_PURE_TRUNCATE_ERROR)) {
		throw new Error(`pure truncate malformed diagnostic mismatch: ${JSON.stringify(diagnostic)}`);
	}
}

for (const capability of CANONICAL_CAPABILITIES) {
	const denialHost = new BrowserWasmToolHost({
		baseUrl: import.meta.url,
		fetchJson: async () => ({
			schemaVersion: "pi-extension.v0",
			artifact: {
				kind: "wasm-component",
				path: "wasm/plugin.wasm",
			},
			tool: {
				id: "fixture.echo",
			},
			capabilities: [capability],
		}),
		fetchBytes: readBytes,
	});
	try {
		await denialHost.initialize("../browser-tool-v0/pi-extension.json");
		throw new Error(`manifest request for ${capability} was unexpectedly granted`);
	} catch (error) {
		if (!(error instanceof DeniedCapabilityError)) throw error;
		assertDeniedCapabilityDiagnostic(error.toDiagnostic(), capability, "manifest-request");
	}
}

for (const capability of CANONICAL_CAPABILITIES) {
	const result = await attemptRuntimeImport(capability);
	if (!result.ok) {
		throw new Error(`unexpected runtime denial diagnostic: ${JSON.stringify(result)}`);
	}
	assertDeniedCapabilityDiagnostic(result.error, capability, "runtime/import");
}

await runNetworkInstrumentationCleanupEvidence();
await runInjectedFailureCleanupEvidence();

console.log("browser wasm harness smoke passed");

function assertClientSideZeroImportEvidence(label, initEvidence) {
	if (initEvidence.runtime !== "browser WebAssembly.instantiate") {
		throw new Error(`${label} did not use browser WebAssembly.instantiate: ${JSON.stringify(initEvidence)}`);
	}
	if (initEvidence.importCount !== 0) {
		throw new Error(`${label} exposed host imports: ${JSON.stringify(initEvidence)}`);
	}
}

function assertDeniedCapabilityDiagnostic(diagnostic, capability, mode) {
	const expectedMessage = `Capability ${capability} is denied by the browser Wasm host in ${mode} mode.`;
	if (
		diagnostic.category !== "denied_capability" ||
		diagnostic.capability !== capability ||
		diagnostic.mode !== mode ||
		diagnostic.message !== expectedMessage
	) {
		throw new Error(
			`unexpected ${mode} denial diagnostic for ${capability}: ${JSON.stringify(diagnostic)}`,
		);
	}
}

async function runNetworkInstrumentationCleanupEvidence() {
	await assertPortRangeClear("before browser network instrumentation");
	let fixtureServer = null;
	try {
		fixtureServer = await startFixtureServer();
		const baseUrl = `http://${HARNESS_HOST}:${fixtureServer.port}/browser-host-v0/index.html`;
		const networkLog = [];
		const tracedFetch = async (input, init) => {
			const url = typeof input === "string" ? input : input.url;
			const href = new URL(url, baseUrl).href;
			networkLog.push({
				method: init?.method ?? "GET",
				url: href,
			});
			return fetch(href, init);
		};
		const fetchJson = async (url) => {
			const response = await tracedFetch(url);
			if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status}`);
			return response.json();
		};
		const fetchBytes = async (url) => {
			const response = await tracedFetch(url);
			if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status}`);
			return new Uint8Array(await response.arrayBuffer());
		};

		const networkHost = new BrowserWasmToolHost({
			baseUrl,
			fetchJson,
			fetchBytes,
		});
		const networkInitEvidence = await networkHost.initialize("../browser-tool-v0/pi-extension.json");
		assertClientSideZeroImportEvidence("network browser fixture", networkInitEvidence);
		assertArtifactFetchEvidence(networkLog, "browser-tool-v0/wasm/plugin.wasm");
		const beforeExecuteCount = networkLog.length;
		const networkOutput = networkHost.execute(VALID_FIXTURE_INPUT);
		if (!validateFixtureOutput(networkOutput)) {
			throw new Error(`network fixture output mismatch: ${JSON.stringify(networkOutput)}`);
		}
		assertNoExecutionEndpointRequests(networkLog.slice(beforeExecuteCount), "browser fixture execute");

		const pureNetworkHost = new BrowserWasmToolHost({
			baseUrl,
			fetchJson,
			fetchBytes,
		});
		const pureNetworkInitEvidence = await pureNetworkHost.initialize(PURE_TRUNCATE_MANIFEST);
		assertClientSideZeroImportEvidence("network pure truncate fixture", pureNetworkInitEvidence);
		assertArtifactFetchEvidence(networkLog, "pure-truncate-head-v0/wasm/plugin.wasm");
		const beforePureExecuteCount = networkLog.length;
		const pureNetworkOutput = pureNetworkHost.execute(VALID_PURE_TRUNCATE_INPUT);
		if (!validatePureTruncateOutput(pureNetworkOutput)) {
			throw new Error(`network pure truncate output mismatch: ${JSON.stringify(pureNetworkOutput)}`);
		}
		assertNoExecutionEndpointRequests(networkLog.slice(beforePureExecuteCount), "pure truncate execute");
		assertNoExecutionEndpointRequests(networkLog, "browser harness network log");
		console.log(
			`browser wasm harness network evidence passed: port=${fixtureServer.port} requests=${networkLog.length}`,
		);
	} finally {
		await closeFixtureServer(fixtureServer);
	}
	await assertPortRangeClear("after browser network instrumentation");
}

async function runInjectedFailureCleanupEvidence() {
	await assertPortRangeClear("before injected failure cleanup");
	let fixtureServer = null;
	let injectedFailureObserved = false;
	try {
		fixtureServer = await startFixtureServer();
		await fetch(`http://${HARNESS_HOST}:${fixtureServer.port}/browser-host-v0/index.html`);
		throw new Error("injected browser harness cleanup failure");
	} catch (error) {
		if (error instanceof Error && error.message === "injected browser harness cleanup failure") {
			injectedFailureObserved = true;
		} else {
			throw error;
		}
	} finally {
		await closeFixtureServer(fixtureServer);
	}
	if (!injectedFailureObserved) {
		throw new Error("injected failure cleanup path did not execute");
	}
	await assertPortRangeClear("after injected failure cleanup");
	console.log("browser wasm harness injected failure cleanup passed");
}

async function startFixtureServer() {
	let lastListenError = null;
	for (const port of HARNESS_PORTS) {
		const server = createServer(async (request, response) => {
			try {
				const requestUrl = new URL(request.url ?? "/", `http://${HARNESS_HOST}:${port}`);
				const pathFromRoot =
					requestUrl.pathname === "/"
						? "browser-host-v0/index.html"
						: decodeURIComponent(requestUrl.pathname.replace(/^\/+/, ""));
				const normalizedPath = normalize(pathFromRoot);
				if (normalizedPath.startsWith("..") || normalizedPath.startsWith("/")) {
					response.writeHead(403);
					response.end("forbidden");
					return;
				}
				const filePath = join(FIXTURE_ROOT, normalizedPath);
				const body = await readFile(filePath);
				response.writeHead(200, { "content-type": contentType(filePath) });
				response.end(body);
			} catch (error) {
				if (error?.code === "ENOENT") {
					response.writeHead(404);
					response.end("not found");
					return;
				}
				response.writeHead(500);
				response.end(error instanceof Error ? error.message : String(error));
			}
		});
		try {
			await listenOnPort(server, port);
			return { server, port };
		} catch (error) {
			await closeFixtureServer({ server });
			if (error?.code === "EADDRINUSE") {
				lastListenError = error;
				continue;
			}
			throw error;
		}
	}
	throw new Error(
		`no free browser harness port in ${HARNESS_PORTS[0]}-${HARNESS_PORTS[HARNESS_PORTS.length - 1]}: ${
			lastListenError instanceof Error ? lastListenError.message : "all ports unavailable"
		}`,
	);
}

async function listenOnPort(server, port) {
	await new Promise((resolve, reject) => {
		const onError = (error) => {
			server.off("listening", onListening);
			reject(error);
		};
		const onListening = () => {
			server.off("error", onError);
			resolve();
		};
		server.once("error", onError);
		server.once("listening", onListening);
		server.listen(port, HARNESS_HOST);
	});
}

async function closeFixtureServer(fixtureServer) {
	if (!fixtureServer?.server?.listening) return;
	await new Promise((resolve, reject) => {
		fixtureServer.server.close((error) => {
			if (error) reject(error);
			else resolve();
		});
	});
}

async function assertPortRangeClear(context) {
	await delay(50);
	const listeningPorts = [];
	for (const port of HARNESS_PORTS) {
		if (await isPortListening(port)) listeningPorts.push(port);
	}
	if (listeningPorts.length !== 0) {
		throw new Error(`${context}: browser harness ports still listening: ${listeningPorts.join(", ")}`);
	}
}

async function isPortListening(port) {
	return new Promise((resolve) => {
		const socket = createConnection({ host: HARNESS_HOST, port });
		const settle = (listening) => {
			socket.removeAllListeners();
			socket.destroy();
			resolve(listening);
		};
		socket.once("connect", () => settle(true));
		socket.once("error", () => settle(false));
		socket.setTimeout(200, () => settle(false));
	});
}

function assertArtifactFetchEvidence(networkLog, artifactPathSuffix) {
	const artifactFetch = networkLog.find((request) => new URL(request.url).pathname.endsWith(artifactPathSuffix));
	if (!artifactFetch) {
		throw new Error(`missing artifact fetch evidence for ${artifactPathSuffix}: ${JSON.stringify(networkLog)}`);
	}
}

function assertNoExecutionEndpointRequests(requests, label) {
	const executionRequests = requests.filter((request) =>
		EXECUTION_ENDPOINT_PATTERN.test(new URL(request.url).pathname),
	);
	if (executionRequests.length !== 0) {
		throw new Error(`${label} made execution endpoint requests: ${JSON.stringify(executionRequests)}`);
	}
}

function contentType(filePath) {
	switch (extname(filePath)) {
		case ".html":
			return "text/html; charset=utf-8";
		case ".js":
			return "text/javascript; charset=utf-8";
		case ".json":
			return "application/json; charset=utf-8";
		case ".wasm":
			return "application/wasm";
		default:
			return "application/octet-stream";
	}
}
