import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import {
	BrowserWasmToolHost,
	DeniedCapabilityError,
	VALID_FIXTURE_INPUT,
	attemptRuntimeImport,
	validateFixtureOutput,
} from "./browser-wasm-host.js";

const readJson = async (url) => JSON.parse(await readFile(fileURLToPath(url), "utf8"));
const readBytes = async (url) => new Uint8Array(await readFile(fileURLToPath(url)));

const host = new BrowserWasmToolHost({
	baseUrl: import.meta.url,
	fetchJson: readJson,
	fetchBytes: readBytes,
});

await host.initialize("../browser-tool-v0/pi-extension.json");
const output = host.execute(VALID_FIXTURE_INPUT);
if (!validateFixtureOutput(output)) {
	throw new Error(`valid fixture output mismatch: ${JSON.stringify(output)}`);
}

for (const [capability, manifest] of [
	["shell", "../browser-tool-v0/shell-request.pi-extension.json"],
	["file.read", "../browser-tool-v0/filesystem-request.pi-extension.json"],
]) {
	const denialHost = new BrowserWasmToolHost({
		baseUrl: import.meta.url,
		fetchJson: readJson,
		fetchBytes: readBytes,
	});
	try {
		await denialHost.initialize(manifest);
		throw new Error(`manifest request for ${capability} was unexpectedly granted`);
	} catch (error) {
		if (!(error instanceof DeniedCapabilityError)) throw error;
		if (error.capability !== capability || error.mode !== "manifest-request") {
			throw new Error(`unexpected manifest denial diagnostic: ${JSON.stringify(error.toDiagnostic())}`);
		}
	}
}

for (const capability of ["shell", "file.read"]) {
	const result = await attemptRuntimeImport(capability);
	if (!result.ok || result.error.category !== "denied_capability" || result.error.mode !== "runtime/import") {
		throw new Error(`unexpected runtime denial diagnostic: ${JSON.stringify(result)}`);
	}
}

console.log("browser wasm harness smoke passed");
