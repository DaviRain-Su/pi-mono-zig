#!/usr/bin/env bash
set -euo pipefail

echo "Bedrock parity: checking TypeScript fixtures are current and read-only"
npx tsx test/generate-bedrock-fixtures.ts --check

echo "Bedrock parity: running Zig semantic request/stream comparator and negative suite"
zig build run-bedrock-parity

echo "Bedrock parity: rerunning comparator for deterministic stability"
zig build run-bedrock-parity

echo "Bedrock parity: complete"
