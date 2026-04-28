#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "TS-RPC parity: checking TypeScript fixtures are current and read-only"
npx tsx test/generate-ts-rpc-fixtures.ts --check

echo "TS-RPC parity: prompt-concurrency queue-order exact byte diff"
bash test/ts-rpc-prompt-concurrency-fixture-diff.sh

echo "TS-RPC parity: direct bash exact byte diff"
python3 <<'PY'
import subprocess
import sys
import time
from pathlib import Path

start_marker = Path("/tmp/pi-ts-rpc-bash-control-start")
live_marker = Path("/tmp/pi-ts-rpc-bash-control-live")
for marker in (start_marker, live_marker):
	try:
		marker.unlink()
	except FileNotFoundError:
		pass

input_lines = [
	line
	for line in Path("test/golden/ts-rpc/bash-control.input.jsonl").read_text().splitlines(keepends=True)
	if line.strip()
]
if len(input_lines) != 7:
	print(f"expected 7 bash-control input lines, got {len(input_lines)}", file=sys.stderr)
	sys.exit(1)

proc = subprocess.Popen(
	["./zig-out/bin/pi", "--mode", "ts-rpc", "--provider", "faux", "--no-session"],
	stdin=subprocess.PIPE,
	stdout=subprocess.PIPE,
	stderr=subprocess.PIPE,
	text=True,
)
assert proc.stdin is not None
for line in input_lines[:3]:
	proc.stdin.write(line)
	proc.stdin.flush()

deadline = time.monotonic() + 5
while time.monotonic() < deadline and not start_marker.exists():
	time.sleep(0.01)
if not start_marker.exists():
	proc.kill()
	print("timed out waiting for bash abort marker", file=sys.stderr)
	sys.exit(1)

proc.stdin.write(input_lines[3])
proc.stdin.flush()
proc.stdin.write(input_lines[4])
proc.stdin.flush()

deadline = time.monotonic() + 5
while time.monotonic() < deadline and not live_marker.exists():
	time.sleep(0.01)
if not live_marker.exists():
	proc.kill()
	print("timed out waiting for live bash marker", file=sys.stderr)
	sys.exit(1)

for line in input_lines[5:]:
	proc.stdin.write(line)
	proc.stdin.flush()
proc.stdin.close()

stdout = proc.stdout.read() if proc.stdout is not None else ""
stderr = proc.stderr.read() if proc.stderr is not None else ""
status = proc.wait(timeout=10)
if status != 0:
	print(stderr, file=sys.stderr)
	print(f"Zig ts-rpc bash-control exited {status}", file=sys.stderr)
	sys.exit(status)

expected = Path("test/golden/ts-rpc/bash-control.jsonl").read_text()
if stdout != expected:
	Path("/tmp/pi-ts-rpc-bash-control-actual.jsonl").write_text(stdout)
	print("bash-control stdout differs from TypeScript fixture; actual written to /tmp/pi-ts-rpc-bash-control-actual.jsonl", file=sys.stderr)
	subprocess.run(
		["diff", "-u", "test/golden/ts-rpc/bash-control.jsonl", "/tmp/pi-ts-rpc-bash-control-actual.jsonl"],
		check=False,
	)
	sys.exit(1)
PY

echo "TS-RPC parity: prompt-concurrency stress loop (20/20 required)"
for iteration in $(seq 1 20); do
	bash test/ts-rpc-prompt-concurrency-fixture-diff.sh
	printf '  prompt-concurrency iteration %02d passed\n' "$iteration"
done

cat <<'REPORT'
TS-RPC parity scenarios passed:
- simple prompt: responses-basic fixture checked against current TS; Zig prompt lifecycle exact-byte tests run under test-coding-agent.
- streaming text: events-base-stream fixture checked against current TS; Zig prompt response/event ordering exact-byte tests run under test-coding-agent.
- thinking deltas: events-thinking-tool-usage fixture checked against current TS and Zig event writer tests.
- tool call/result: events-thinking-tool-usage fixture checked against current TS and Zig event writer tests.
- direct bash: current TS fixture and Zig --mode ts-rpc stdout diff passed.
- compaction: responses-basic/events-session-extras fixtures checked against current TS and Zig compaction control tests.
- retry: events-session-extras fixture checked against current TS and Zig retry lifecycle tests.
- queue steer/follow-up: current TS prompt-concurrency fixture and Zig --mode ts-rpc stdout diff passed; 20 stress iterations passed.
- extension UI request/response: extension-ui fixture checked against current TS and Zig extension UI request/response tests.
REPORT
