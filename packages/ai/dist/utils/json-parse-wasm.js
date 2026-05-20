let wasmInstance = null;
let wasmMemory = null;
async function loadWasmBuffer() {
    // In Node.js, use fs to read the WASM file
    if (typeof process !== "undefined" && process.versions?.node) {
        // @ts-expect-error separate file to avoid browser bundler issues
        const node = await import("./json-parse-wasm-node.mjs");
        return node.loadWasmBuffer();
    }
    // In browser, fetch the WASM file
    const response = await fetch(new URL("../../zig-wasm/zig-out/bin/pi-ai-json-parse.wasm", import.meta.url));
    return new Uint8Array(await response.arrayBuffer());
}
async function initWasm() {
    if (wasmInstance)
        return wasmInstance;
    const wasmBuffer = await loadWasmBuffer();
    // @ts-expect-error WebAssembly API not in Node types
    const globalWebAssembly = globalThis.WebAssembly;
    const module = new globalWebAssembly.Module(wasmBuffer);
    const instance = new globalWebAssembly.Instance(module, {});
    // Use the memory exported by the WASM module
    wasmMemory = instance.exports.memory;
    wasmInstance = instance;
    return instance;
}
function readStringFromMemory(memory, ptr, len) {
    const mem = new Uint8Array(memory.buffer);
    const bytes = mem.slice(ptr, ptr + len);
    const decoder = new TextDecoder();
    return decoder.decode(bytes);
}
// Memory layout constants matching Zig code
const INPUT_OFFSET = 0x10000;
const MAX_SIZE = 0x10000;
export async function parseStreamingJsonWasm(partialJson) {
    if (!partialJson || partialJson.trim() === "") {
        return {};
    }
    try {
        const instance = await initWasm();
        const memory = wasmMemory;
        const exports = instance.exports;
        const encoder = new TextEncoder();
        const inputBytes = encoder.encode(partialJson);
        if (inputBytes.length > MAX_SIZE) {
            return {};
        }
        // Write input to fixed input buffer
        new Uint8Array(memory.buffer).set(inputBytes, INPUT_OFFSET);
        // Call WASM function
        const resultPtr = exports.parseJson(INPUT_OFFSET, inputBytes.length);
        if (resultPtr === 0) {
            return {};
        }
        const resultLen = exports.stringLen(resultPtr);
        const resultJson = readStringFromMemory(memory, resultPtr, resultLen);
        return JSON.parse(resultJson);
    }
    catch {
        return {};
    }
}
//# sourceMappingURL=json-parse-wasm.js.map