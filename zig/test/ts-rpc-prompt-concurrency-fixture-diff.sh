#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

actual="$(mktemp "${TMPDIR:-/tmp}/pi-ts-rpc-prompt-concurrency.XXXXXX")"
expected_normalized="$(mktemp "${TMPDIR:-/tmp}/pi-ts-rpc-prompt-concurrency-expected.XXXXXX")"
actual_normalized="$(mktemp "${TMPDIR:-/tmp}/pi-ts-rpc-prompt-concurrency-actual.XXXXXX")"
trap 'rm -f "$actual" "$expected_normalized" "$actual_normalized"' EXIT

./zig-out/bin/pi --mode ts-rpc --provider faux --no-session \
	< test/golden/ts-rpc/prompt-concurrency-queue-order.input.jsonl \
	> "$actual"

python3 - "$actual" "$actual_normalized" <<'PY'
import sys
from pathlib import Path

actual_path = Path(sys.argv[1])
normalized_path = Path(sys.argv[2])
agent_start = '{"type":"agent_start"}\n'
pc_start = '{"id":"pc_start","type":"response","command":"prompt","success":true}\n'

text = actual_path.read_text()
agent_start_count = text.count(agent_start)
if agent_start_count > 1:
	print(f"expected at most one TS-compatible agent_start lifecycle event, saw {agent_start_count}", file=sys.stderr)
	sys.exit(1)
if agent_start_count == 1 and text.index(agent_start) < text.index(pc_start):
	print("agent_start appeared before the prompt acceptance response", file=sys.stderr)
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

normalized_path.write_text("".join(line for line in text.splitlines(keepends=True) if line != agent_start))
PY

python3 - test/golden/ts-rpc/prompt-concurrency-queue-order.jsonl "$expected_normalized" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
agent_start = '{"type":"agent_start"}\n'
target.write_text("".join(line for line in source.read_text().splitlines(keepends=True) if line != agent_start))
PY

diff -u "$expected_normalized" "$actual_normalized"
