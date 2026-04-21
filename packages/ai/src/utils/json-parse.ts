import { parse as partialParse } from "partial-json";

let wasmModule: typeof import("./json-parse-wasm.js") | null = null;

async function loadWasmModule(): Promise<typeof import("./json-parse-wasm.js")> {
	if (wasmModule) return wasmModule;
	wasmModule = await import("./json-parse-wasm.js");
	return wasmModule;
}

/**
 * Attempts to parse potentially incomplete JSON during streaming.
 * Always returns a valid object, even if the JSON is incomplete.
 *
 * @param partialJson The partial JSON string from streaming
 * @returns Parsed object or empty object if parsing fails
 */
export function parseStreamingJson<T = any>(partialJson: string | undefined): T {
	if (!partialJson || partialJson.trim() === "") {
		return {} as T;
	}

	// Try standard parsing first (fastest for complete JSON)
	try {
		return JSON.parse(partialJson) as T;
	} catch {
		// Try partial-json for incomplete JSON
		try {
			const result = partialParse(partialJson);
			return (result ?? {}) as T;
		} catch {
			// If all parsing fails, return empty object
			return {} as T;
		}
	}
}

/**
 * WASM-based JSON parser for streaming partial JSON.
 * Falls back to the JS implementation if WASM fails to load.
 */
export async function parseStreamingJsonWasm<T = any>(partialJson: string | undefined): Promise<T> {
	if (!partialJson || partialJson.trim() === "") {
		return {} as T;
	}

	try {
		const wasm = await loadWasmModule();
		return (await wasm.parseStreamingJsonWasm(partialJson)) as T;
	} catch {
		// Fallback to JS implementation
		return parseStreamingJson(partialJson);
	}
}
