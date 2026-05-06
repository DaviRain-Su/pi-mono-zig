export const CANONICAL_CAPABILITIES = [
	"file.read",
	"file.write",
	"network",
	"shell",
	"env",
	"model",
	"session",
	"ui.notify",
];
const CAPABILITIES = new Set(CANONICAL_CAPABILITIES);
const UNAVAILABLE_BROWSER_CAPABILITIES = new Set(CAPABILITIES);
const textDecoder = new TextDecoder();
const textEncoder = new TextEncoder();

export const VALID_FIXTURE_INPUT = {
	operation: "echo",
	value: "native-wasm",
};

export const EXPECTED_FIXTURE_OUTPUT = {
	ok: true,
	tool: "fixture.echo",
	echo: "native-wasm",
};

export const PURE_TRUNCATE_MANIFEST = "../pure-truncate-head-v0/pi-extension.json";

export const VALID_PURE_TRUNCATE_INPUT = {
	content: "alpha\nbravo\ncharlie\ndelta",
	maxLines: 2,
	maxBytes: 1024,
};

export const EXPECTED_PURE_TRUNCATE_OUTPUT = {
	content: "alpha\nbravo",
	truncated: true,
	truncatedBy: "lines",
	totalLines: 4,
	totalBytes: 25,
	outputLines: 2,
	outputBytes: 11,
	lastLinePartial: false,
	firstLineExceedsLimit: false,
	maxLines: 2,
	maxBytes: 1024,
};

export const EXPECTED_PURE_TRUNCATE_ERROR = {
	ok: false,
	error: {
		category: "invalid_input",
		message: "execute input must be a JSON object",
	},
};

export class DeniedCapabilityError extends Error {
	constructor({ capability, mode, message }) {
		super(message);
		this.name = "DeniedCapabilityError";
		this.category = "denied_capability";
		this.capability = capability;
		this.mode = mode;
	}

	toDiagnostic() {
		return {
			category: this.category,
			capability: this.capability,
			mode: this.mode,
			message: this.message,
		};
	}
}

export class BrowserWasmToolHost {
	constructor(options = {}) {
		this.baseUrl = options.baseUrl ?? globalThis.location?.href ?? "http://127.0.0.1/";
		this.fetchJson = options.fetchJson ?? defaultFetchJson;
		this.fetchBytes = options.fetchBytes ?? defaultFetchBytes;
		this.manifest = null;
		this.manifestUrl = null;
		this.artifactUrl = null;
		this.instance = null;
		this.exports = null;
		this.initialized = false;
	}

	async initialize(manifestUrl) {
		const resolvedManifestUrl = new URL(manifestUrl, this.baseUrl).href;
		const manifest = await this.fetchJson(resolvedManifestUrl);
		validateManifestShape(manifest);
		denyManifestRequestedCapabilities(manifest);

		const artifactUrl = new URL(manifest.artifact.path, resolvedManifestUrl).href;
		const artifactBytes = await this.fetchBytes(artifactUrl);
		const result = await WebAssembly.instantiate(artifactBytes, {});
		const instance = result instanceof WebAssembly.Instance ? result : result.instance;
		validateToolExports(instance.exports);

		this.manifest = manifest;
		this.manifestUrl = resolvedManifestUrl;
		this.artifactUrl = artifactUrl;
		this.instance = instance;
		this.exports = instance.exports;
		this.initialized = true;
		return {
			manifest,
			artifactUrl,
			runtime: "browser WebAssembly.instantiate",
			importCount: WebAssembly.Module.imports(result.module ?? new WebAssembly.Module(artifactBytes)).length,
		};
	}

	metadata() {
		this.requireInitialized();
		return JSON.parse(this.readExportedString("metadata", "metadata_len"));
	}

	schema() {
		this.requireInitialized();
		return JSON.parse(this.readExportedString("schema", "schema_len"));
	}

	execute(input) {
		this.requireInitialized();
		if (typeof input !== "object" || input === null || Array.isArray(input)) {
			throw new Error("execute input must be a JSON object");
		}
		const output = JSON.parse(this.readExportedString("execute", "execute_len"));
		return output;
	}

	readExportedString(pointerExportName, lengthExportName) {
		const pointer = this.exports[pointerExportName]();
		const length = this.exports[lengthExportName]();
		const bytes = new Uint8Array(this.exports.memory.buffer, pointer, length);
		return textDecoder.decode(bytes);
	}

	requireInitialized() {
		if (!this.initialized) throw new Error("browser Wasm host is not initialized");
	}
}

export function validateFixtureOutput(output) {
	return (
		output.ok === EXPECTED_FIXTURE_OUTPUT.ok &&
		output.tool === EXPECTED_FIXTURE_OUTPUT.tool &&
		output.echo === EXPECTED_FIXTURE_OUTPUT.echo
	);
}

export function validatePureTruncateOutput(output) {
	return JSON.stringify(output) === JSON.stringify(EXPECTED_PURE_TRUNCATE_OUTPUT);
}

export function normalizePureToolError(error) {
	if (error instanceof Error && error.message === EXPECTED_PURE_TRUNCATE_ERROR.error.message) {
		return EXPECTED_PURE_TRUNCATE_ERROR;
	}
	return {
		ok: false,
		error: {
			category: "unexpected_error",
			message: error instanceof Error ? error.message : String(error),
		},
	};
}

export async function attemptRuntimeImport(capability) {
	const spec = runtimeImportSpec(capability);
	const bytes = createImportAttemptModule(spec.moduleName, spec.fieldName);
	const imports = {
		[spec.moduleName]: {
			[spec.fieldName]: () => {
				throw deniedCapability(spec.capability, "runtime/import");
			},
		},
	};
	const result = await WebAssembly.instantiate(bytes, imports);
	const instance = result instanceof WebAssembly.Instance ? result : result.instance;
	try {
		instance.exports.execute();
		return {
			ok: false,
			error: {
				category: "unexpected_capability_grant",
				capability: spec.capability,
				mode: "runtime/import",
				message: `Capability ${spec.capability} was unexpectedly granted.`,
			},
		};
	} catch (error) {
		if (error instanceof DeniedCapabilityError) {
			return {
				ok: true,
				error: error.toDiagnostic(),
			};
		}
		throw error;
	}
}

export function createImportAttemptModule(moduleName, fieldName) {
	const typeSection = section(1, [1, 0x60, 0, 1, 0x7f]);
	const importSection = section(2, [1, ...encodeName(moduleName), ...encodeName(fieldName), 0, 0]);
	const functionSection = section(3, [1, 0]);
	const exportSection = section(7, [1, ...encodeName("execute"), 0, 1]);
	const codeSection = section(10, [1, 4, 0, 0x10, 0, 0x0b]);
	return Uint8Array.from([
		0,
		0x61,
		0x73,
		0x6d,
		1,
		0,
		0,
		0,
		...typeSection,
		...importSection,
		...functionSection,
		...exportSection,
		...codeSection,
	]);
}

function runtimeImportSpec(capability) {
	switch (capability) {
		case "file.read":
			return { capability, moduleName: "pi:filesystem", fieldName: "read" };
		case "file.write":
			return { capability, moduleName: "pi:filesystem", fieldName: "write" };
		case "network":
			return { capability, moduleName: "pi:network", fieldName: "fetch" };
		case "shell":
			return { capability, moduleName: "pi:shell", fieldName: "run" };
		case "env":
			return { capability, moduleName: "pi:environment", fieldName: "get" };
		case "model":
			return { capability, moduleName: "pi:model", fieldName: "call" };
		case "session":
			return { capability, moduleName: "pi:session", fieldName: "get" };
		case "ui.notify":
			return { capability, moduleName: "pi:ui", fieldName: "notify" };
		default:
			throw new Error(`unsupported runtime import fixture capability: ${capability}`);
	}
}

function validateManifestShape(manifest) {
	if (manifest?.schemaVersion !== "pi-extension.v0") {
		throw new Error("invalid manifest: $.schemaVersion must be pi-extension.v0");
	}
	if (manifest.artifact?.kind !== "wasm-component") {
		throw new Error("invalid manifest: $.artifact.kind must be wasm-component");
	}
	if (typeof manifest.artifact?.path !== "string" || !manifest.artifact.path.endsWith(".wasm")) {
		throw new Error("invalid manifest: $.artifact.path must point to a .wasm file");
	}
	if (typeof manifest.tool?.id !== "string") {
		throw new Error("invalid manifest: $.tool.id is required");
	}
}

function denyManifestRequestedCapabilities(manifest) {
	const capabilities = manifest.capabilities ?? [];
	if (!Array.isArray(capabilities)) {
		throw new Error("invalid manifest: $.capabilities must be an array when present");
	}
	for (const capability of capabilities) {
		if (!CAPABILITIES.has(capability)) {
			throw new Error(`invalid manifest: unknown capability ${capability}`);
		}
		if (UNAVAILABLE_BROWSER_CAPABILITIES.has(capability)) {
			throw deniedCapability(capability, "manifest-request");
		}
	}
}

function deniedCapability(capability, mode) {
	return new DeniedCapabilityError({
		capability,
		mode,
		message: `Capability ${capability} is denied by the browser Wasm host in ${mode} mode.`,
	});
}

function validateToolExports(exports) {
	for (const name of ["metadata", "metadata_len", "schema", "schema_len", "execute", "execute_len"]) {
		if (typeof exports[name] !== "function") {
			throw new Error(`Wasm fixture is missing required export ${name}`);
		}
	}
	if (!(exports.memory instanceof WebAssembly.Memory)) {
		throw new Error("Wasm fixture is missing exported memory");
	}
}

async function defaultFetchJson(url) {
	const response = await fetch(url);
	if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status}`);
	return response.json();
}

async function defaultFetchBytes(url) {
	const response = await fetch(url);
	if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status}`);
	return new Uint8Array(await response.arrayBuffer());
}

function section(id, payload) {
	return [id, ...encodeU32(payload.length), ...payload];
}

function encodeName(name) {
	const bytes = textEncoder.encode(name);
	return [...encodeU32(bytes.length), ...bytes];
}

function encodeU32(value) {
	const out = [];
	let remaining = value >>> 0;
	do {
		let byte = remaining & 0x7f;
		remaining >>>= 7;
		if (remaining !== 0) byte |= 0x80;
		out.push(byte);
	} while (remaining !== 0);
	return out;
}

function wireBrowserHarness() {
	const networkLog = [];
	const originalFetch = globalThis.fetch.bind(globalThis);
	const tracedFetch = async (input, init) => {
		const url = typeof input === "string" ? input : input.url;
		const href = new URL(url, globalThis.location.href).href;
		networkLog.push({
			method: init?.method ?? "GET",
			url: href,
			at: new Date().toISOString(),
		});
		return originalFetch(input, init);
	};

	globalThis.PI_BROWSER_HARNESS_NETWORK = networkLog;

	const host = new BrowserWasmToolHost({
		baseUrl: globalThis.location.href,
		fetchJson: async (url) => {
			const response = await tracedFetch(url);
			if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status}`);
			return response.json();
		},
		fetchBytes: async (url) => {
			const response = await tracedFetch(url);
			if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status}`);
			return new Uint8Array(await response.arrayBuffer());
		},
	});

	const state = {
		host,
		networkLog,
	};
	globalThis.PI_BROWSER_HARNESS = state;

	const output = document.querySelector("#output");
	const status = document.querySelector("#host-status");
	const network = document.querySelector("#network-evidence");

	const print = (value) => {
		output.textContent = typeof value === "string" ? value : JSON.stringify(value, null, 2);
	};

	const renderNetwork = (beforeCount) => {
		const newRequests = networkLog.slice(beforeCount);
		const executionApiRequests = newRequests.filter((request) =>
			/\/(execute|invoke|run|tool-call)(\/|\?|$)/i.test(new URL(request.url).pathname),
		);
		network.textContent = [
			`Network requests during action: ${newRequests.length}`,
			`Execution API requests during action: ${executionApiRequests.length}`,
			"Execution mode: client-side browser WebAssembly.instantiate; no server execution endpoint is used.",
		].join("\n");
		return { newRequests, executionApiRequests };
	};

	const runManifestDenial = async (manifestUrl) => {
		const denialHost = new BrowserWasmToolHost({
			baseUrl: globalThis.location.href,
			fetchJson: async (url) => {
				const response = await tracedFetch(url);
				if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status}`);
				return response.json();
			},
			fetchBytes: host.fetchBytes,
		});
		try {
			await denialHost.initialize(manifestUrl);
			print({
				ok: false,
				error: {
					category: "unexpected_capability_grant",
					message: "Manifest-request capability was unexpectedly granted.",
				},
			});
		} catch (error) {
			if (error instanceof DeniedCapabilityError) {
				print({ ok: true, error: error.toDiagnostic() });
				return;
			}
			throw error;
		}
	};

	const runCapabilityDenialMatrix = async () => {
		const manifestRequests = [];
		for (const capability of CANONICAL_CAPABILITIES) {
			const denialHost = new BrowserWasmToolHost({
				baseUrl: globalThis.location.href,
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
				fetchBytes: host.fetchBytes,
			});
			try {
				await denialHost.initialize("../browser-tool-v0/pi-extension.json");
				manifestRequests.push({
					ok: false,
					error: {
						category: "unexpected_capability_grant",
						capability,
						mode: "manifest-request",
						message: `Capability ${capability} was unexpectedly granted.`,
					},
				});
			} catch (error) {
				if (error instanceof DeniedCapabilityError) {
					manifestRequests.push({ ok: true, error: error.toDiagnostic() });
				} else {
					throw error;
				}
			}
		}
		const runtimeImports = [];
		for (const capability of CANONICAL_CAPABILITIES) {
			runtimeImports.push(await attemptRuntimeImport(capability));
		}
		const allDenied = [...manifestRequests, ...runtimeImports].every(
			(result) => result.ok && result.error.category === "denied_capability",
		);
		print({
			ok: allDenied,
			capabilities: CANONICAL_CAPABILITIES,
			manifestRequests,
			runtimeImports,
		});
	};

	const runPureTruncate = async () => {
		const beforeCount = networkLog.length;
		const pureHost = new BrowserWasmToolHost({
			baseUrl: globalThis.location.href,
			fetchJson: async (url) => {
				const response = await tracedFetch(url);
				if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status}`);
				return response.json();
			},
			fetchBytes: async (url) => {
				const response = await tracedFetch(url);
				if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status}`);
				return new Uint8Array(await response.arrayBuffer());
			},
		});
		await pureHost.initialize(PURE_TRUNCATE_MANIFEST);
		const outputValue = pureHost.execute(VALID_PURE_TRUNCATE_INPUT);
		let malformed;
		try {
			pureHost.execute([]);
			malformed = { ok: false, error: { category: "unexpected_success" } };
		} catch (error) {
			malformed = normalizePureToolError(error);
		}
		const networkEvidence = renderNetwork(beforeCount);
		print({
			ok:
				validatePureTruncateOutput(outputValue) &&
				JSON.stringify(malformed) === JSON.stringify(EXPECTED_PURE_TRUNCATE_ERROR) &&
				networkEvidence.executionApiRequests.length === 0,
			manifest: PURE_TRUNCATE_MANIFEST,
			artifact: pureHost.artifactUrl,
			input: VALID_PURE_TRUNCATE_INPUT,
			output: outputValue,
			expected: EXPECTED_PURE_TRUNCATE_OUTPUT,
			malformed,
			clientSide: networkEvidence.executionApiRequests.length === 0,
		});
	};

	document.querySelector("#run-fixture").addEventListener("click", () => {
		const beforeCount = networkLog.length;
		const result = host.execute(VALID_FIXTURE_INPUT);
		const networkEvidence = renderNetwork(beforeCount);
		print({
			ok: validateFixtureOutput(result) && networkEvidence.newRequests.length === 0,
			input: VALID_FIXTURE_INPUT,
			output: result,
			expected: EXPECTED_FIXTURE_OUTPUT,
			clientSide: networkEvidence.newRequests.length === 0 && networkEvidence.executionApiRequests.length === 0,
		});
	});
	document.querySelector("#run-pure-truncate").addEventListener("click", runPureTruncate);
	document.querySelector("#deny-shell-manifest").addEventListener("click", async () => {
		const beforeCount = networkLog.length;
		await runManifestDenial("../browser-tool-v0/shell-request.pi-extension.json");
		renderNetwork(beforeCount);
	});
	document.querySelector("#deny-filesystem-manifest").addEventListener("click", async () => {
		const beforeCount = networkLog.length;
		await runManifestDenial("../browser-tool-v0/filesystem-request.pi-extension.json");
		renderNetwork(beforeCount);
	});
	document.querySelector("#deny-shell-runtime").addEventListener("click", async () => {
		const beforeCount = networkLog.length;
		const result = await attemptRuntimeImport("shell");
		renderNetwork(beforeCount);
		print(result);
	});
	document.querySelector("#deny-filesystem-runtime").addEventListener("click", async () => {
		const beforeCount = networkLog.length;
		const result = await attemptRuntimeImport("file.read");
		renderNetwork(beforeCount);
		print(result);
	});
	document.querySelector("#run-capability-denial-matrix").addEventListener("click", async () => {
		const beforeCount = networkLog.length;
		await runCapabilityDenialMatrix();
		renderNetwork(beforeCount);
	});

	host
		.initialize("../browser-tool-v0/pi-extension.json")
		.then((init) => {
			status.textContent = `initialized: ${init.manifest.tool.id}; artifact=${init.artifactUrl}; imports=${init.importCount}; runtime=${init.runtime}`;
			network.textContent = `Initialization network requests: ${networkLog.length}`;
			print({
				status: "initialized",
				metadata: host.metadata(),
				schema: host.schema(),
			});
		})
		.catch((error) => {
			status.textContent = "failed";
			print({ ok: false, error: error instanceof Error ? error.message : String(error) });
		});
}

if (typeof document !== "undefined") {
	wireBrowserHarness();
}
