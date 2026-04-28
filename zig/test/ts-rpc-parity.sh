#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "TS-RPC parity: checking TypeScript fixtures are current and read-only"
npx tsx test/generate-ts-rpc-fixtures.ts --check

echo "TS-RPC parity: prompt-concurrency queue-order exact byte diff"
bash test/ts-rpc-prompt-concurrency-fixture-diff.sh

echo "TS-RPC parity: live production scenario exact byte diffs"
python3 <<'PY'
import os
import subprocess
import sys
import time
from pathlib import Path

BASE_ARGS = [
	"./zig-out/bin/pi",
	"--mode",
	"ts-rpc",
	"--provider",
	"faux",
	"--no-session",
	"--no-extensions",
	"--no-context-files",
	"--no-prompt-templates",
	"--system-prompt",
	"sys",
]

SCENARIOS = [
	(
		"m5-simple-prompt",
		{"PI_FAUX_RESPONSE": "faux response"},
		1.0,
		"simple prompt + streaming text",
	),
	(
		"m5-thinking",
		{"PI_FAUX_THINKING": "Need exact bytes.", "PI_FAUX_RESPONSE": "final answer"},
		1.0,
		"thinking deltas",
	),
	(
		"m5-tool",
		{
			"PI_FAUX_TOOL_NAME": "bash",
			"PI_FAUX_TOOL_ARGS_JSON": '{"command":"printf tool-ok"}',
			"PI_FAUX_TOOL_FINAL_RESPONSE": "done",
			"PI_FIXED_NOW_MS": "1766880000008",
		},
		2.0,
		"tool call/result",
	),
	(
		"m5-compaction",
		{"PI_FAUX_RESPONSE": "compact summary"},
		1.0,
		"compaction",
	),
	(
		"m5-retry",
		{"PI_FAUX_STOP_REASON": "error", "PI_FAUX_ERROR_MESSAGE": "503 service unavailable"},
		3.0,
		"retry",
	),
]

for name, env_extra, settle_seconds, label in SCENARIOS:
	input_path = Path(f"test/golden/ts-rpc/{name}.input.jsonl")
	expected_path = Path(f"test/golden/ts-rpc/{name}.jsonl")
	actual_path = Path(f"/tmp/pi-ts-rpc-{name}-actual.jsonl")
	input_bytes = input_path.read_text()
	env = os.environ.copy()
	env.update(env_extra)
	proc = subprocess.Popen(
		BASE_ARGS,
		stdin=subprocess.PIPE,
		stdout=subprocess.PIPE,
		stderr=subprocess.PIPE,
		text=True,
		env=env,
	)
	assert proc.stdin is not None
	proc.stdin.write(input_bytes)
	proc.stdin.flush()
	time.sleep(settle_seconds)
	proc.stdin.close()
	stdout = proc.stdout.read() if proc.stdout is not None else ""
	stderr = proc.stderr.read() if proc.stderr is not None else ""
	status = proc.wait(timeout=10)
	if status != 0:
		print(stderr, file=sys.stderr)
		print(f"{name} Zig ts-rpc exited {status}", file=sys.stderr)
		sys.exit(status)
	expected = expected_path.read_text()
	if stdout != expected:
		actual_path.write_text(stdout)
		print(f"{name} ({label}) stdout differs; actual written to {actual_path}", file=sys.stderr)
		subprocess.run(["diff", "-u", str(expected_path), str(actual_path)], check=False)
		sys.exit(1)
	print(f"  {label} exact byte diff passed")

extension_response_input = (
	'{"type":"extension_ui_response","id":"ui_select","value":"option-a"}\n'
	'{"type":"extension_ui_response","id":"ui_confirm","confirmed":true}\n'
	'{"type":"extension_ui_response","id":"ui_input","cancelled":true}\n'
)
proc = subprocess.run(
	BASE_ARGS,
	input=extension_response_input,
	text=True,
	stdout=subprocess.PIPE,
	stderr=subprocess.PIPE,
	check=False,
)
if proc.returncode != 0:
	print(proc.stderr, file=sys.stderr)
	print(f"extension_ui_response Zig ts-rpc exited {proc.returncode}", file=sys.stderr)
	sys.exit(proc.returncode)
if proc.stdout != "":
	Path("/tmp/pi-ts-rpc-extension-ui-response-actual.jsonl").write_text(proc.stdout)
	print("extension_ui_response should be consumed without stdout", file=sys.stderr)
	sys.exit(1)
print("  extension UI response consumption exact byte diff passed")
PY

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
- simple prompt: current TS fixture and Zig --mode ts-rpc stdout diff passed.
- streaming text: current TS fixture and Zig --mode ts-rpc stdout diff passed.
- thinking deltas: current TS fixture and Zig --mode ts-rpc stdout diff passed.
- tool call/result: current TS fixture and Zig --mode ts-rpc stdout diff passed.
- direct bash: current TS fixture and Zig --mode ts-rpc stdout diff passed.
- compaction: current TS fixture and Zig --mode ts-rpc stdout diff passed.
- retry: current TS fixture and Zig --mode ts-rpc stdout diff passed.
- queue steer/follow-up: current TS prompt-concurrency fixture and Zig --mode ts-rpc stdout diff passed; 20 stress iterations passed.
- extension UI request/response: extension-ui fixture checked against current TS; Zig --mode ts-rpc consumes extension_ui_response without stdout, and request bytes are covered by Zig extension UI exact-byte tests.
REPORT
