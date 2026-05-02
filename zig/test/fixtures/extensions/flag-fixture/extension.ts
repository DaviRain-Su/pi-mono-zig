// Local Bun fixture extension for M11 extension CLI flag passthrough
// validation. The extension stub exists so `--extension <path>` can
// resolve a real file; the CLI flag set the extension contributes is
// declared in the deterministic sidecar manifest
// `extension.flags.json` next to this file. Live Bun JSONL flag
// registration is exercised by the sibling `m11-extension-registration-surfaces`
// feature and is not required for CLI flag passthrough/help integration.

export default function activate(): void {
  // No runtime side effects in the CLI-flag fixture.
}
