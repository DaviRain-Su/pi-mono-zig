// Local Bun fixture extension for M11 extension registration surfaces
// validation. The extension stub exists so `--extension <path>` can
// resolve a real file. The registration frames it would emit live
// extensions via the Bun JSONL protocol are mirrored in the
// deterministic sidecar manifest `extension.registry.jsonl` next to
// this file. Tests load the registry frames from the sidecar and
// assert that the parsed Zig registry matches what the live Bun
// extension would produce.

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export default function activate(pi: ExtensionAPI): void {
  pi.registerTool({
    name: "say-hello",
    label: "Say Hello",
    description: "Greets the world (fixture tool)",
    parameters: {} as never,
    async execute() {
      return { content: [{ type: "text", text: "hello" }], isError: false };
    },
  });

  pi.registerCommand("say-hello", {
    description: "Slash command for say-hello",
    async handler() {
      // no-op fixture handler
    },
  });

  pi.registerShortcut("ctrl+h", {
    description: "Trigger say-hello",
    async handler() {
      // no-op fixture handler
    },
  });

  pi.registerFlag("plan", {
    type: "boolean",
    description: "Enable plan mode (fixture flag)",
    default: true,
  });

  pi.registerFlag("model-alias", {
    type: "string",
    description: "Model alias override (fixture flag)",
    default: "claude-haiku",
  });

  pi.registerProvider("fake-provider", {
    name: "Fake Provider",
    baseUrl: "http://localhost:0",
    api: "openai-completions",
    apiKey: "FAKE_API_KEY",
    models: [
      {
        id: "fake-model-1",
        name: "Fake Model 1",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128_000,
        maxTokens: 4096,
      },
      {
        id: "fake-model-2",
        name: "Fake Model 2",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128_000,
        maxTokens: 4096,
      },
    ],
  });
}
