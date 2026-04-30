#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "OpenAI Responses parity: checking TypeScript fixtures are current and read-only"
npx tsx test/generate-openai-responses-fixtures.ts --check
echo "OpenAI Responses parity: comparing Zig-built semantic requests to TypeScript snapshots"
zig build run-openai-responses-parity
