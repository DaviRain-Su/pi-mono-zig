#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "OpenAI Chat parity: checking TypeScript fixtures are current and read-only"
npx tsx test/generate-openai-chat-fixtures.ts --check

echo "OpenAI Chat parity: comparing Zig-built semantic requests to TypeScript snapshots"
zig build run-openai-chat-parity
