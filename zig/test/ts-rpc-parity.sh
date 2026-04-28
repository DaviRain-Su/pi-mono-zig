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
import queue
import subprocess
import sys
import threading
import time
import tempfile
from pathlib import Path
from urllib.parse import quote

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

def emit_ts_fixture(name):
	proc = subprocess.run(
		["npx", "tsx", "test/generate-ts-rpc-fixtures.ts", f"--emit-fixture={name}"],
		stdout=subprocess.PIPE,
		stderr=subprocess.PIPE,
		text=True,
		check=False,
	)
	if proc.returncode != 0:
		print(proc.stderr, file=sys.stderr)
		print(f"TypeScript RPC fixture emission failed for {name}", file=sys.stderr)
		sys.exit(proc.returncode)
	return proc.stdout

for name, env_extra, settle_seconds, label in SCENARIOS:
	input_path = Path(f"test/golden/ts-rpc/{name}.input.jsonl")
	actual_path = Path(f"/tmp/pi-ts-rpc-{name}-actual.jsonl")
	input_bytes = input_path.read_text()
	ts_stdout = emit_ts_fixture(f"{name}.jsonl")
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
	if stdout != ts_stdout:
		actual_path.write_text(stdout)
		with tempfile.NamedTemporaryFile("w", delete=False, prefix=f"pi-ts-rpc-{name}-ts-", suffix=".jsonl") as ts_file:
			ts_file.write(ts_stdout)
			ts_path = ts_file.name
		print(f"{name} ({label}) stdout differs from live TypeScript RPC output; actual written to {actual_path}", file=sys.stderr)
		subprocess.run(["diff", "-u", ts_path, str(actual_path)], check=False)
		sys.exit(1)
	print(f"  {label} live TS-vs-Zig exact byte diff passed")

extension_response_input = (
	'{"type":"extension_ui_response","id":"ui_select","value":"option-a"}\n'
	'{"type":"extension_ui_response","id":"ui_confirm","confirmed":true}\n'
	'{"type":"extension_ui_response","id":"ui_input","cancelled":true}\n'
)
ts_extension_response = subprocess.run(
	["npx", "tsx", "test/generate-ts-rpc-fixtures.ts", "--runtime-child=responses-basic"],
	input=extension_response_input,
	text=True,
	stdout=subprocess.PIPE,
	stderr=subprocess.PIPE,
	check=False,
)
if ts_extension_response.returncode != 0:
	print(ts_extension_response.stderr, file=sys.stderr)
	print(f"extension_ui_response TypeScript RPC exited {ts_extension_response.returncode}", file=sys.stderr)
	sys.exit(ts_extension_response.returncode)
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
if proc.stdout != ts_extension_response.stdout:
	Path("/tmp/pi-ts-rpc-extension-ui-response-actual.jsonl").write_text(proc.stdout)
	Path("/tmp/pi-ts-rpc-extension-ui-response-ts.jsonl").write_text(ts_extension_response.stdout)
	print("extension_ui_response Zig stdout differs from live TypeScript RPC stdout", file=sys.stderr)
	subprocess.run(
		["diff", "-u", "/tmp/pi-ts-rpc-extension-ui-response-ts.jsonl", "/tmp/pi-ts-rpc-extension-ui-response-actual.jsonl"],
		check=False,
	)
	sys.exit(1)
print("  extension UI response consumption live TS-vs-Zig exact byte diff passed")

def deterministic_crypto_import():
	source = (
		'import { createRequire } from "node:module";\n'
		'const require = createRequire(process.cwd() + "/package.json");\n'
		'const crypto = require("node:crypto");\n'
		'const ids = ["ui_select","ui_confirm","ui_input","ui_notify","ui_status","ui_widget","ui_title","ui_editor_text","ui_editor","ui_extra_1","ui_extra_2"];\n'
		'crypto.randomUUID = () => ids.shift() ?? "ui_extra";\n'
	)
	return f"data:text/javascript,{quote(source)}"

def run_live_extension_ui(args, env, label):
	responses = {
		"ui_select": '{"type":"extension_ui_response","id":"ui_select","value":"option-a"}\n',
		"ui_confirm": '{"type":"extension_ui_response","id":"ui_confirm","confirmed":true}\n',
		"ui_input": '{"type":"extension_ui_response","id":"ui_input","cancelled":true}\n',
		"ui_editor": '{"type":"extension_ui_response","id":"ui_editor","value":"edited text"}\n',
	}
	proc = subprocess.Popen(
		args,
		stdin=subprocess.PIPE,
		stdout=subprocess.PIPE,
		stderr=subprocess.PIPE,
		text=True,
		env=env,
	)
	assert proc.stdin is not None
	assert proc.stdout is not None
	assert proc.stderr is not None
	lines = queue.Queue()

	def read_stdout():
		for line in proc.stdout:
			lines.put(line)

	reader = threading.Thread(target=read_stdout, daemon=True)
	reader.start()
	stdout_lines = []
	sent = set()
	deadline = time.monotonic() + 10
	expected_request_lines = 9
	while len(stdout_lines) < expected_request_lines:
		remaining = deadline - time.monotonic()
		if remaining <= 0:
			proc.kill()
			print(f"{label} timed out waiting for extension_ui_request output", file=sys.stderr)
			sys.exit(1)
		try:
			line = lines.get(timeout=remaining)
		except queue.Empty:
			proc.kill()
			print(f"{label} timed out waiting for extension_ui_request output", file=sys.stderr)
			sys.exit(1)
		stdout_lines.append(line)
		for request_id, response in responses.items():
			if request_id not in sent and f'"id":"{request_id}"' in line:
				proc.stdin.write(response)
				proc.stdin.flush()
				sent.add(request_id)

	missing = sorted(set(responses) - sent)
	if missing:
		proc.kill()
		print(f"{label} did not emit dialog request ids: {', '.join(missing)}", file=sys.stderr)
		sys.exit(1)
	proc.stdin.close()
	stderr = proc.stderr.read()
	status = proc.wait(timeout=10)
	reader.join(timeout=1)
	while True:
		try:
			stdout_lines.append(lines.get_nowait())
		except queue.Empty:
			break
	if status != 0:
		print(stderr, file=sys.stderr)
		print(f"{label} exited {status}", file=sys.stderr)
		sys.exit(status)
	return "".join(stdout_lines)

ts_extension_ui_stdout = run_live_extension_ui(
	[
		"node",
		"--import",
		deterministic_crypto_import(),
		"--import",
		"tsx",
		"test/generate-ts-rpc-fixtures.ts",
		"--runtime-child=extension-ui",
	],
	os.environ.copy(),
	"extension UI TypeScript RPC",
)
zig_extension_ui_env = os.environ.copy()
zig_extension_ui_env["PI_TS_RPC_EXTENSION_UI_PARITY_SCENARIO"] = "1"
zig_extension_ui_stdout = run_live_extension_ui(
	[
		"./zig-out/bin/pi",
		"--mode",
		"ts-rpc",
		"--provider",
		"faux",
		"--no-session",
		"--no-context-files",
		"--no-prompt-templates",
		"--system-prompt",
		"sys",
	],
	zig_extension_ui_env,
	"extension UI Zig ts-rpc",
)
if zig_extension_ui_stdout != ts_extension_ui_stdout:
	Path("/tmp/pi-ts-rpc-extension-ui-live-actual.jsonl").write_text(zig_extension_ui_stdout)
	Path("/tmp/pi-ts-rpc-extension-ui-live-ts.jsonl").write_text(ts_extension_ui_stdout)
	print("extension UI live request/response Zig stdout differs from live TypeScript RPC stdout", file=sys.stderr)
	subprocess.run(
		["diff", "-u", "/tmp/pi-ts-rpc-extension-ui-live-ts.jsonl", "/tmp/pi-ts-rpc-extension-ui-live-actual.jsonl"],
		check=False,
	)
	sys.exit(1)
print("  extension UI live request emission + response consumption TS-vs-Zig exact byte diff passed")
PY

echo "TS-RPC parity: extension UI request writer exact byte coverage"
zig build test-coding-agent -- --test-filter "TS RPC extension UI request writer matches TypeScript fixture bytes"

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

ts_expected = subprocess.run(
	["npx", "tsx", "test/generate-ts-rpc-fixtures.ts", "--emit-fixture=bash-control.jsonl"],
	stdout=subprocess.PIPE,
	stderr=subprocess.PIPE,
	text=True,
	check=False,
)
if ts_expected.returncode != 0:
	print(ts_expected.stderr, file=sys.stderr)
	print(f"TypeScript RPC bash-control emission exited {ts_expected.returncode}", file=sys.stderr)
	sys.exit(ts_expected.returncode)
if stdout != ts_expected.stdout:
	Path("/tmp/pi-ts-rpc-bash-control-actual.jsonl").write_text(stdout)
	Path("/tmp/pi-ts-rpc-bash-control-ts.jsonl").write_text(ts_expected.stdout)
	print("bash-control stdout differs from live TypeScript RPC output; actual written to /tmp/pi-ts-rpc-bash-control-actual.jsonl", file=sys.stderr)
	subprocess.run(
		["diff", "-u", "/tmp/pi-ts-rpc-bash-control-ts.jsonl", "/tmp/pi-ts-rpc-bash-control-actual.jsonl"],
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
- simple prompt: live TypeScript RPC runtime stdout and Zig --mode ts-rpc stdout diff passed.
- streaming text: live TypeScript RPC runtime stdout and Zig --mode ts-rpc stdout diff passed.
- thinking deltas: live TypeScript RPC runtime stdout and Zig --mode ts-rpc stdout diff passed.
- tool call/result: live TypeScript RPC runtime stdout and Zig --mode ts-rpc stdout diff passed.
- direct bash: live TypeScript RPC runtime stdout and Zig --mode ts-rpc stdout diff passed.
- compaction: live TypeScript RPC runtime stdout and Zig --mode ts-rpc stdout diff passed.
- retry: live TypeScript RPC runtime stdout and Zig --mode ts-rpc stdout diff passed.
- queue steer/follow-up: live TypeScript RPC runtime stdout and Zig --mode ts-rpc stdout diff passed; 20 stress iterations passed.
- extension UI request/response: live TypeScript RPC runtime and Zig --mode ts-rpc emitted extension_ui_request bytes, consumed matching extension_ui_response inputs while running, and exact-byte stdout diff passed.
REPORT
