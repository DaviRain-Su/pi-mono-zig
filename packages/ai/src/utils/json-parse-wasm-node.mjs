import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export function loadWasmBuffer() {
	const __filename = fileURLToPath(import.meta.url);
	const __dirname = dirname(__filename);
	const wasmPath = join(__dirname, "..", "..", "zig-wasm", "zig-out", "bin", "pi-ai-json-parse.wasm");
	return readFileSync(wasmPath);
}
