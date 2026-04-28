#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

actual="$(mktemp "${TMPDIR:-/tmp}/pi-ts-rpc-prompt-concurrency.XXXXXX")"
expected="$(mktemp "${TMPDIR:-/tmp}/pi-ts-rpc-prompt-concurrency-ts.XXXXXX")"
trap 'rm -f "$actual" "$expected"' EXIT

npx tsx test/generate-ts-rpc-fixtures.ts --emit-fixture=prompt-concurrency-queue-order.jsonl > "$expected"

./zig-out/bin/pi --mode ts-rpc --provider faux --no-session \
	< test/golden/ts-rpc/prompt-concurrency-queue-order.input.jsonl \
	> "$actual"

python3 - "$actual" "$expected" <<'PY'
import sys
from pathlib import Path

actual_path = Path(sys.argv[1])
expected_path = Path(sys.argv[2])
agent_start = '{"type":"agent_start"}\n'
pc_start = '{"id":"pc_start","type":"response","command":"prompt","success":true}\n'

text = actual_path.read_text()
expected = expected_path.read_text()
if agent_start in text:
	print("prompt-concurrency TS fixture does not emit agent_start; Zig output must match that exact lifecycle slot", file=sys.stderr)
	sys.exit(1)
if pc_start not in text:
	print("missing prompt acceptance response", file=sys.stderr)
	sys.exit(1)
if agent_start in expected:
	print("live TypeScript prompt-concurrency output unexpectedly emitted agent_start", file=sys.stderr)
	sys.exit(1)

checks = [
	(
		'{"type":"queue_update","steering":["steer while prompt running"],"followUp":[]}\n',
		'{"id":"pc_steer","type":"response","command":"steer","success":true}\n',
	),
	(
		'{"type":"queue_update","steering":["steer while prompt running"],"followUp":["follow while prompt running"]}\n',
		'{"id":"pc_follow","type":"response","command":"follow_up","success":true}\n',
	),
	(
		'{"type":"queue_update","steering":["steer while prompt running","prompt as steer"],"followUp":["follow while prompt running"]}\n',
		'{"id":"pc_prompt_steer","type":"response","command":"prompt","success":true}\n',
	),
	(
		'{"type":"queue_update","steering":["steer while prompt running","prompt as steer"],"followUp":["follow while prompt running","prompt as follow"]}\n',
		'{"id":"pc_prompt_follow","type":"response","command":"prompt","success":true}\n',
	),
]
for before, after in checks:
	try:
		before_index = text.index(before)
		after_index = text.index(after)
	except ValueError as exc:
		print(f"missing expected line while checking queue ordering: {exc}", file=sys.stderr)
		sys.exit(1)
	if before_index > after_index:
		print(f"queue_update did not precede related response:\n{before}{after}", file=sys.stderr)
		sys.exit(1)
PY

diff -u "$expected" "$actual"
