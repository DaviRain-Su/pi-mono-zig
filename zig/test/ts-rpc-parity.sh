#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

for name in "${!PI_M6_EXTENSION_HOST_@}"; do
	unset "$name"
done

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

M6_HOST_ENV_PREFIX = "PI_M6_EXTENSION_HOST_"

def clean_child_env(env_extra=None):
	env = {
		key: value
		for key, value in os.environ.items()
		if not key.startswith(M6_HOST_ENV_PREFIX)
	}
	if env_extra:
		env.update(env_extra)
	return env

def emit_ts_fixture(name):
	proc = subprocess.run(
		["npx", "tsx", "test/generate-ts-rpc-fixtures.ts", f"--emit-fixture={name}"],
		stdout=subprocess.PIPE,
		stderr=subprocess.PIPE,
		text=True,
		env=clean_child_env(),
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
	env = clean_child_env(env_extra)
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
	env=clean_child_env(),
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
	env=clean_child_env(),
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
		'const ids = ["ui_select","ui_confirm","ui_input","ui_notify","ui_status","ui_widget","ui_title","ui_editor_text","ui_editor","ui_m6_complete","ui_extra_1","ui_extra_2"];\n'
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
	clean_child_env(),
	"extension UI TypeScript RPC",
)
zig_extension_ui_env = clean_child_env({"PI_TS_RPC_EXTENSION_UI_PARITY_SCENARIO": "1"})
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

def host_process_count(marker):
	proc = subprocess.run(["ps", "axo", "command"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
	if proc.returncode != 0:
		print(proc.stderr, file=sys.stderr)
		print("failed to inspect process table for M6 host marker", file=sys.stderr)
		sys.exit(proc.returncode)
	return sum(1 for line in proc.stdout.splitlines() if marker in line)

def read_jsonl(path):
	return [line for line in Path(path).read_text().splitlines() if line.strip()]

def assert_m6_capture(path, marker):
	records = []
	for line in read_jsonl(path):
		try:
			records.append(__import__("json").loads(line))
		except Exception as exc:
			print(f"M6 host capture contains invalid JSONL: {exc}", file=sys.stderr)
			sys.exit(1)
	initializes = [record for record in records if record.get("event") == "initialize"]
	ready = [record for record in records if record.get("event") == "ready"]
	completions = [record for record in records if record.get("event") == "completion"]
	if len(initializes) != 1 or initializes[0].get("marker") != marker or initializes[0].get("fixture") != "m6-extension-host":
		print(f"M6 host capture initialize evidence invalid: {initializes}", file=sys.stderr)
		sys.exit(1)
	if len(ready) != 1:
		print(f"M6 host capture ready evidence invalid: {ready}", file=sys.stderr)
		sys.exit(1)
	if len(completions) != 1:
		print(f"M6 host capture completion evidence invalid: {completions}", file=sys.stderr)
		sys.exit(1)
	response_records = [
		{"event": record.get("event"), "id": record.get("id"), "payload": record.get("payload")}
		for record in records
		if record.get("event") == "response"
	]
	expected_responses = [
		{"event": "response", "id": "ui_confirm", "payload": {"confirmed": True}},
		{"event": "response", "id": "ui_select", "payload": {"value": "option-b"}},
		{"event": "response", "id": "ui_input", "payload": {"cancelled": True}},
		{"event": "response", "id": "ui_editor", "payload": {"value": "edited text"}},
	]
	if response_records != expected_responses:
		print(f"M6 host capture response payload evidence invalid: {response_records}", file=sys.stderr)
		sys.exit(1)
	completion_result = completions[0].get("result")
	expected_completion_result = {
		"select": "option-b",
		"confirmed": True,
		"input": "cancelled",
		"editor": "edited text",
	}
	if completion_result != expected_completion_result:
		print(f"M6 host capture completion result invalid: {completion_result}", file=sys.stderr)
		sys.exit(1)

def run_m6_configured(label, marker, expected_stdout, response_input):
	if host_process_count(marker) != 0:
		print(f"{label} found pre-existing M6 host marker process: {marker}", file=sys.stderr)
		sys.exit(1)
	capture_path = Path(tempfile.gettempdir()) / f"{marker}-capture.jsonl"
	try:
		capture_path.unlink()
	except FileNotFoundError:
		pass
	env = clean_child_env({
		"PI_M6_EXTENSION_HOST_ENTRY": "test/m6-extension-host-fixture.mjs",
		"PI_M6_EXTENSION_HOST_RUNTIME": "bun",
		"PI_M6_EXTENSION_HOST_FIXTURE": "m6-extension-host",
		"PI_M6_EXTENSION_HOST_MARKER": marker,
		"PI_M6_EXTENSION_HOST_CAPTURE": str(capture_path),
	})
	proc = subprocess.Popen(
		BASE_ARGS,
		stdin=subprocess.PIPE,
		stdout=subprocess.PIPE,
		stderr=subprocess.PIPE,
		text=True,
		env=env,
	)
	assert proc.stdin is not None
	assert proc.stdout is not None
	assert proc.stderr is not None
	initial_lines = []
	for _ in range(9):
		line = proc.stdout.readline()
		if not line:
			stderr = proc.stderr.read()
			proc.kill()
			print(stderr, file=sys.stderr)
			print(f"{label} ended before initial M6 request matrix", file=sys.stderr)
			sys.exit(1)
		initial_lines.append(line)
	active_count = host_process_count(marker)
	if active_count != 1:
		proc.kill()
		print(f"{label} expected one active M6 host marker process, found {active_count}", file=sys.stderr)
		sys.exit(1)
	for line in response_input.splitlines(keepends=True):
		proc.stdin.write(line)
		proc.stdin.flush()
	completion_line = proc.stdout.readline()
	if not completion_line:
		stderr = proc.stderr.read()
		proc.kill()
		print(stderr, file=sys.stderr)
		print(f"{label} ended before M6 completion request", file=sys.stderr)
		sys.exit(1)
	proc.stdin.close()
	remaining_stdout = proc.stdout.read()
	stderr = proc.stderr.read()
	status = proc.wait(timeout=10)
	stdout = "".join(initial_lines) + completion_line + remaining_stdout
	if status != 0:
		print(stderr, file=sys.stderr)
		print(f"{label} Zig ts-rpc exited {status}", file=sys.stderr)
		sys.exit(status)
	if stdout != expected_stdout:
		actual_path = Path(tempfile.gettempdir()) / f"{marker}-actual.jsonl"
		expected_path = Path(tempfile.gettempdir()) / f"{marker}-ts.jsonl"
		actual_path.write_text(stdout)
		expected_path.write_text(expected_stdout)
		print(f"{label} public stdout differs from live TypeScript RPC output; actual written to {actual_path}", file=sys.stderr)
		subprocess.run(["diff", "-u", str(expected_path), str(actual_path)], check=False)
		sys.exit(1)
	if not capture_path.exists():
		print(f"{label} did not write M6 side-channel host capture", file=sys.stderr)
		sys.exit(1)
	assert_m6_capture(capture_path, marker)
	if host_process_count(marker) != 0:
		print(f"{label} left an M6 host marker process running: {marker}", file=sys.stderr)
		sys.exit(1)
	return stdout

def run_m6_without_host(label, env_extra, response_input, marker):
	capture_path = Path(tempfile.gettempdir()) / f"{marker}-capture.jsonl"
	try:
		capture_path.unlink()
	except FileNotFoundError:
		pass
	env = clean_child_env({**env_extra, "PI_M6_EXTENSION_HOST_CAPTURE": str(capture_path)})
	proc = subprocess.run(
		BASE_ARGS,
		input=response_input,
		text=True,
		stdout=subprocess.PIPE,
		stderr=subprocess.PIPE,
		env=env,
		check=False,
	)
	if proc.returncode != 0:
		print(proc.stderr, file=sys.stderr)
		print(f"{label} Zig ts-rpc exited {proc.returncode}", file=sys.stderr)
		sys.exit(proc.returncode)
	if proc.stdout != "":
		print(f"{label} unexpectedly emitted public stdout: {proc.stdout}", file=sys.stderr)
		sys.exit(1)
	if capture_path.exists():
		print(f"{label} unexpectedly wrote M6 side-channel host capture", file=sys.stderr)
		sys.exit(1)
	if host_process_count(marker) != 0:
		print(f"{label} left an M6 host marker process running: {marker}", file=sys.stderr)
		sys.exit(1)

m6_ts_stdout = emit_ts_fixture("m6-extension-host.jsonl")
m6_response_input = emit_ts_fixture("m6-extension-host.input.jsonl")
run_m6_configured("M6 configured extension host", "pi-m6-extension-host-configured", m6_ts_stdout, m6_response_input)
run_m6_without_host(
	"M6 unconfigured extension host",
	{},
	m6_response_input,
	"pi-m6-extension-host-unconfigured",
)
run_m6_without_host(
	"M6 disabled extension host",
	{
		"PI_M6_EXTENSION_HOST_ENTRY": "test/m6-extension-host-fixture.mjs",
		"PI_M6_EXTENSION_HOST_RUNTIME": "bun",
		"PI_M6_EXTENSION_HOST_FIXTURE": "m6-extension-host",
		"PI_M6_EXTENSION_HOST_MARKER": "pi-m6-extension-host-disabled",
		"PI_M6_EXTENSION_HOST_DISABLED": "1",
	},
	m6_response_input,
	"pi-m6-extension-host-disabled",
)
first_mode_switch = run_m6_configured(
	"M6 mode-switch configured first run",
	"pi-m6-extension-host-mode-switch-a",
	m6_ts_stdout,
	m6_response_input,
)
run_m6_without_host(
	"M6 mode-switch disabled middle run",
	{
		"PI_M6_EXTENSION_HOST_ENTRY": "test/m6-extension-host-fixture.mjs",
		"PI_M6_EXTENSION_HOST_RUNTIME": "bun",
		"PI_M6_EXTENSION_HOST_FIXTURE": "m6-extension-host",
		"PI_M6_EXTENSION_HOST_MARKER": "pi-m6-extension-host-mode-switch-disabled",
		"PI_M6_EXTENSION_HOST_DISABLED": "1",
	},
	m6_response_input,
	"pi-m6-extension-host-mode-switch-disabled",
)
second_mode_switch = run_m6_configured(
	"M6 mode-switch configured second run",
	"pi-m6-extension-host-mode-switch-b",
	m6_ts_stdout,
	m6_response_input,
)
if first_mode_switch != second_mode_switch:
	print("M6 configured mode-switch runs produced different public stdout", file=sys.stderr)
	sys.exit(1)
print("  M6 extension host configured, disabled/unconfigured, multi-request, and mode-switch parity passed")
PY

echo "TS-RPC parity: extension UI request writer exact byte coverage"
zig build test-coding-agent -- --test-filter "TS RPC extension UI request writer matches TypeScript fixture bytes"

echo "TS-RPC parity: direct bash exact byte diff"
python3 <<'PY'
import os
import subprocess
import sys
import time
from pathlib import Path

M6_HOST_ENV_PREFIX = "PI_M6_EXTENSION_HOST_"

def clean_child_env(env_extra=None):
	env = {
		key: value
		for key, value in os.environ.items()
		if not key.startswith(M6_HOST_ENV_PREFIX)
	}
	if env_extra:
		env.update(env_extra)
	return env

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
	env=clean_child_env(),
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
	env=clean_child_env(),
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
- M6 extension host fixture: live TypeScript RPC runtime stdout and Zig configured host stdout diff passed; side-channel host capture verified init/ready/responses/completion separately from public stdout; disabled/unconfigured and repeated mode-switch runs emitted no stale host output.
REPORT
