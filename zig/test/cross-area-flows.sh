#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_PATH="${PI_BINARY:-$ROOT_DIR/zig-out/bin/pi}"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Binary not found: $BIN_PATH" >&2
  exit 1
fi

if ! command -v tuistory >/dev/null 2>&1; then
  echo "blocked-by-tuistory: VAL-CROSS-013 cross-area TUI integration checks require tuistory; non-TUI Zig validators remain runnable" >&2
  exit 0
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pi-cross-area.XXXXXX")"
INTERACTIVE_SESSION="pi-cross-area-$$"

cleanup() {
  tuistory -s "$INTERACTIVE_SESSION" close >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

log() {
  printf '[cross-area] %s\n' "$1"
}

latest_session_file() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

session_dir = Path(sys.argv[1])
paths = sorted(
    session_dir.glob("*.jsonl"),
    key=lambda path: (path.stat().st_mtime_ns, path.name),
    reverse=True,
)
if not paths:
    raise SystemExit(f"no session files found in {session_dir}")
print(paths[0])
PY
}

assert_messages_equal() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

session_path = sys.argv[1]
expected = sys.argv[2].split("\n")

messages = []
with open(session_path, "r", encoding="utf-8") as handle:
    for raw_line in handle:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        entry = json.loads(raw_line)
        if entry.get("type") != "message":
            continue
        message = entry["message"]
        role = message.get("role")
        if role not in {"user", "assistant"}:
            continue
        content = message.get("content")
        if isinstance(content, str):
            messages.append(content)
            continue
        if not content:
            continue
        first = content[0]
        if isinstance(first, dict) and first.get("type") == "text":
            messages.append(first.get("text", ""))

if messages != expected:
    raise SystemExit(f"unexpected message sequence: {messages!r} != {expected!r}")
PY
}

assert_no_messages() {
  python3 - "$1" <<'PY'
import json
import sys

session_path = sys.argv[1]
messages = []
with open(session_path, "r", encoding="utf-8") as handle:
    for raw_line in handle:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        entry = json.loads(raw_line)
        if entry.get("type") == "message":
            messages.append(entry)

if messages:
    raise SystemExit(f"expected no message entries, found {len(messages)}")
PY
}

assert_parent_session() {
  python3 - "$1" "$2" <<'PY'
import json
from pathlib import Path
import sys

session_path = sys.argv[1]
expected_parent = str(Path(sys.argv[2]).resolve())

with open(session_path, "r", encoding="utf-8") as handle:
    for raw_line in handle:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        header = json.loads(raw_line)
        if header.get("type") != "session":
            raise SystemExit(f"expected session header, got {header!r}")
        actual = header.get("parentSession")
        actual_resolved = str(Path(actual).resolve()) if actual else actual
        if actual_resolved != expected_parent:
            raise SystemExit(f"unexpected parentSession: {actual!r} != {expected_parent!r}")
        break
    else:
        raise SystemExit("missing session header")
PY
}

assert_tool_entries() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

session_path = sys.argv[1]
expected_path = sys.argv[2]
saw_tool_call = False
saw_tool_result = False
saw_final_response = False

with open(session_path, "r", encoding="utf-8") as handle:
    for raw_line in handle:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        entry = json.loads(raw_line)
        if entry.get("type") != "message":
            continue
        message = entry["message"]
        role = message.get("role")
        if role == "assistant":
            for item in message.get("content") or []:
                if item.get("type") == "toolCall" and item.get("name") == "read":
                    if item.get("arguments", {}).get("path") == expected_path:
                        saw_tool_call = True
                if item.get("type") == "text" and item.get("text") == "The file says: secret note":
                    saw_final_response = True
        elif role == "toolResult":
            if message.get("toolName") == "read":
                content = message.get("content") or []
                if content and content[0].get("type") == "text" and content[0].get("text") == "secret note":
                    saw_tool_result = True

if not saw_tool_call:
    raise SystemExit("tool call entry missing from session jsonl")
if not saw_tool_result:
    raise SystemExit("tool result entry missing from session jsonl")
if not saw_final_response:
    raise SystemExit("final assistant response missing from session jsonl")
PY
}

assert_multi_provider_entries() {
  python3 - "$1" <<'PY'
import json
import sys

session_path = sys.argv[1]
assistant_providers = []

with open(session_path, "r", encoding="utf-8") as handle:
    for raw_line in handle:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        entry = json.loads(raw_line)
        entry_type = entry.get("type")
        if entry_type == "message":
            message = entry["message"]
            if message.get("role") == "assistant":
                assistant_providers.append(message.get("provider"))

if assistant_providers[:2] != ["openai", "anthropic"]:
    raise SystemExit(f"unexpected assistant providers: {assistant_providers!r}")
PY
}

assert_compaction_summary() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

session_path = sys.argv[1]
needle = sys.argv[2]

summaries = []
with open(session_path, "r", encoding="utf-8") as handle:
    for raw_line in handle:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        entry = json.loads(raw_line)
        if entry.get("type") == "compaction":
            summaries.append(entry.get("summary", ""))

if not summaries:
    raise SystemExit("expected at least one compaction entry")
if not any(needle in summary for summary in summaries):
    raise SystemExit(f"expected compaction summary to mention {needle!r}: {summaries!r}")
PY
}

assert_no_ansi() {
  local value="$1"
  if [[ "$value" == *$'\033'* ]]; then
    echo "unexpected ANSI escape sequence in output" >&2
    exit 1
  fi
}

assert_startup_prompt_round_trip_session() {
  python3 - "$1" <<'PY'
import json
import sys

session_path = sys.argv[1]
messages = []
ansi_paths = []

def walk(value, path):
    if isinstance(value, str):
        if "\x1b" in value:
            ansi_paths.append(path)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            walk(item, f"{path}[{index}]")
    elif isinstance(value, dict):
        for key, item in value.items():
            walk(item, f"{path}.{key}")

with open(session_path, "r", encoding="utf-8") as handle:
    for line_number, raw_line in enumerate(handle, 1):
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        entry = json.loads(raw_line)
        walk(entry, f"line{line_number}")
        if entry.get("type") != "message":
            continue
        message = entry["message"]
        role = message.get("role")
        if role not in {"user", "assistant"}:
            continue
        content = message.get("content")
        text = ""
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            text = "".join(
                item.get("text", "")
                for item in content
                if isinstance(item, dict) and item.get("type") == "text"
            )
        messages.append((role, text))

if ansi_paths:
    raise SystemExit(f"ANSI escape byte persisted in JSONL string fields: {ansi_paths!r}")

expected = [("user", "hello cross prompt"), ("assistant", "hello from cross-area")]
if messages != expected:
    raise SystemExit(f"unexpected persisted message sequence: {messages!r} != {expected!r}")
PY
}

assert_cross_area_labels_unambiguous() {
  python3 - "$0" <<'PY'
import re
import sys
from pathlib import Path

script = Path(sys.argv[1]).read_text(encoding="utf-8")
allowed_current_contract_ids = {
    "VAL-CROSS-001",
    "VAL-CROSS-002",
    "VAL-CROSS-005",
    "VAL-CROSS-007",
    "VAL-CROSS-008",
    "VAL-CROSS-009",
    "VAL-CROSS-011",
    "VAL-CROSS-012",
    "VAL-CROSS-013",
}
labels = set(re.findall(r"VAL-CROSS-\d{3}", script))
unexpected = sorted(labels - allowed_current_contract_ids)
if unexpected:
    raise SystemExit(f"ambiguous current-contract labels in cross-area script: {unexpected!r}")
PY
}

log "VAL-CROSS-013 script labels map only to current contract assertions and blocked checks are environment-gated"
assert_cross_area_labels_unambiguous

make_case_dirs() {
  local name="$1"
  mkdir -p "$TMP_ROOT/$name/agent" "$TMP_ROOT/$name/home" "$TMP_ROOT/$name/project"
}

log "VAL-CROSS-001 startup prompt round trip persists exactly once"
make_case_dirs "chat"
CHAT_AGENT="$TMP_ROOT/chat/agent"
CHAT_HOME="$TMP_ROOT/chat/home"
CHAT_PROJECT="$TMP_ROOT/chat/project"

tuistory -s "$INTERACTIVE_SESSION" close >/dev/null 2>&1 || true
tuistory launch "$BIN_PATH --provider faux --model faux-1" \
  -s "$INTERACTIVE_SESSION" \
  --cwd "$CHAT_PROJECT" \
  --cols 120 \
  --rows 30 \
  --env "HOME=$CHAT_HOME" \
  --env "PI_CODING_AGENT_DIR=$CHAT_AGENT" \
  --env "PI_FAUX_FORCE=1" \
  --env "PI_FAUX_RESPONSE=hello from cross-area"
tuistory -s "$INTERACTIVE_SESSION" wait "Welcome to pi" --timeout 8000
tuistory -s "$INTERACTIVE_SESSION" type "hello cross prompt"
tuistory -s "$INTERACTIVE_SESSION" press enter
tuistory -s "$INTERACTIVE_SESSION" wait "hello from cross-area" --timeout 8000
tuistory -s "$INTERACTIVE_SESSION" wait-idle --timeout 3000
chat_snapshot="$(tuistory -s "$INTERACTIVE_SESSION" snapshot --trim)"
assert_no_ansi "$chat_snapshot"
printf '%s\n' "$chat_snapshot" | grep -F "hello cross prompt" >/dev/null
printf '%s\n' "$chat_snapshot" | grep -F "hello from cross-area" >/dev/null
printf '%s\n' "$chat_snapshot" | grep -F "Model:" >/dev/null
tuistory -s "$INTERACTIVE_SESSION" close >/dev/null 2>&1 || true
chat_session_file="$(latest_session_file "$CHAT_PROJECT/.pi/sessions")"
assert_startup_prompt_round_trip_session "$chat_session_file"

log "LEGACY-CROSS-TOOL tool-augmented conversation"
make_case_dirs "tool"
TOOL_AGENT="$TMP_ROOT/tool/agent"
TOOL_HOME="$TMP_ROOT/tool/home"
TOOL_PROJECT="$TMP_ROOT/tool/project"
TOOL_NOTE="$TOOL_PROJECT/note.txt"
printf 'secret note' > "$TOOL_NOTE"
TOOL_ARGS_JSON="$(python3 - "$TOOL_NOTE" <<'PY'
import json
import sys
print(json.dumps({"path": sys.argv[1]}))
PY
)"

tool_output="$(
  cd "$TOOL_PROJECT"
  env \
    HOME="$TOOL_HOME" \
    PI_CODING_AGENT_DIR="$TOOL_AGENT" \
    PI_FAUX_TOOL_NAME="read" \
    PI_FAUX_TOOL_ARGS_JSON="$TOOL_ARGS_JSON" \
    PI_FAUX_TOOL_FINAL_RESPONSE="The file says: secret note" \
    "$BIN_PATH" --provider faux --tools read --print "what is in the file?"
)"
[[ "$tool_output" == "The file says: secret note" ]]
tool_session_file="$(latest_session_file "$TOOL_PROJECT/.pi/sessions")"
assert_tool_entries "$tool_session_file" "$TOOL_NOTE"

log "LEGACY-CROSS-SESSION session persistence across runs"
make_case_dirs "session"
SESSION_AGENT="$TMP_ROOT/session/agent"
SESSION_HOME="$TMP_ROOT/session/home"
SESSION_PROJECT="$TMP_ROOT/session/project"

first_output="$(
  cd "$SESSION_PROJECT"
  env \
    HOME="$SESSION_HOME" \
    PI_CODING_AGENT_DIR="$SESSION_AGENT" \
    PI_FAUX_RESPONSE="first reply" \
    "$BIN_PATH" --provider faux --print "first prompt"
)"
[[ "$first_output" == "first reply" ]]

second_output="$(
  cd "$SESSION_PROJECT"
  env \
    HOME="$SESSION_HOME" \
    PI_CODING_AGENT_DIR="$SESSION_AGENT" \
    PI_FAUX_RESPONSE="second reply" \
    "$BIN_PATH" --provider faux --print --continue "second prompt"
)"
[[ "$second_output" == "second reply" ]]
session_file="$(latest_session_file "$SESSION_PROJECT/.pi/sessions")"
assert_messages_equal "$session_file" $'first prompt\nfirst reply\nsecond prompt\nsecond reply'

log "VAL-CROSS-009 session lifecycle across new resume fork restart"
make_case_dirs "lifecycle"
LIFECYCLE_AGENT="$TMP_ROOT/lifecycle/agent"
LIFECYCLE_HOME="$TMP_ROOT/lifecycle/home"
LIFECYCLE_PROJECT="$TMP_ROOT/lifecycle/project"

original_lifecycle_output="$(
  cd "$LIFECYCLE_PROJECT"
  env \
    HOME="$LIFECYCLE_HOME" \
    PI_CODING_AGENT_DIR="$LIFECYCLE_AGENT" \
    PI_FAUX_RESPONSE="lifecycle reply" \
    "$BIN_PATH" --provider faux --print "lifecycle original prompt"
)"
[[ "$original_lifecycle_output" == "lifecycle reply" ]]
original_lifecycle_session="$(latest_session_file "$LIFECYCLE_PROJECT/.pi/sessions")"

tuistory -s "$INTERACTIVE_SESSION" close >/dev/null 2>&1 || true
tuistory launch "$BIN_PATH --provider faux --model faux-1 --session $original_lifecycle_session" \
  -s "$INTERACTIVE_SESSION" \
  --cwd "$LIFECYCLE_PROJECT" \
  --cols 140 \
  --rows 36 \
  --env "HOME=$LIFECYCLE_HOME" \
  --env "PI_CODING_AGENT_DIR=$LIFECYCLE_AGENT" \
  --env "PI_FAUX_FORCE=1" \
  --env "PI_FAUX_RESPONSE=lifecycle reply"
tuistory -s "$INTERACTIVE_SESSION" wait "lifecycle original prompt" --timeout 8000
tuistory -s "$INTERACTIVE_SESSION" wait "lifecycle reply" --timeout 8000
tuistory -s "$INTERACTIVE_SESSION" type "/new"
tuistory -s "$INTERACTIVE_SESSION" press enter
tuistory -s "$INTERACTIVE_SESSION" press enter
tuistory -s "$INTERACTIVE_SESSION" wait "New session started" --timeout 5000
new_lifecycle_session="$(latest_session_file "$LIFECYCLE_PROJECT/.pi/sessions")"
if [[ "$new_lifecycle_session" == "$original_lifecycle_session" ]]; then
  echo "expected /new to create a different session file" >&2
  exit 1
fi
tuistory -s "$INTERACTIVE_SESSION" type "/resume"
tuistory -s "$INTERACTIVE_SESSION" press enter
tuistory -s "$INTERACTIVE_SESSION" wait "Session selector" --timeout 5000
tuistory -s "$INTERACTIVE_SESSION" press down
tuistory -s "$INTERACTIVE_SESSION" press enter
tuistory -s "$INTERACTIVE_SESSION" wait "lifecycle original prompt" --timeout 5000
tuistory -s "$INTERACTIVE_SESSION" wait "lifecycle reply" --timeout 5000
tuistory -s "$INTERACTIVE_SESSION" type "/fork"
tuistory -s "$INTERACTIVE_SESSION" press enter
tuistory -s "$INTERACTIVE_SESSION" wait "Fork from Message" --timeout 5000
tuistory -s "$INTERACTIVE_SESSION" press enter
fork_prompt_snapshot="$(tuistory -s "$INTERACTIVE_SESSION" snapshot --trim)"
printf '%s\n' "$fork_prompt_snapshot" | grep -F "lifecycle original prompt" >/dev/null
fork_lifecycle_session="$(latest_session_file "$LIFECYCLE_PROJECT/.pi/sessions")"
if [[ "$fork_lifecycle_session" == "$original_lifecycle_session" || "$fork_lifecycle_session" == "$new_lifecycle_session" ]]; then
  echo "expected /fork to create a different session file" >&2
  exit 1
fi
tuistory -s "$INTERACTIVE_SESSION" close >/dev/null 2>&1 || true

assert_messages_equal "$original_lifecycle_session" $'lifecycle original prompt\nlifecycle reply'
assert_parent_session "$fork_lifecycle_session" "$original_lifecycle_session"
assert_no_messages "$fork_lifecycle_session"

log "LEGACY-CROSS-INTERACTIVE-TOOL interactive tool execution"
make_case_dirs "interactive"
INTERACTIVE_AGENT="$TMP_ROOT/interactive/agent"
INTERACTIVE_HOME="$TMP_ROOT/interactive/home"
INTERACTIVE_PROJECT="$TMP_ROOT/interactive/project"
INTERACTIVE_NOTE="$INTERACTIVE_PROJECT/note.txt"
printf 'secret note' > "$INTERACTIVE_NOTE"
INTERACTIVE_ARGS_JSON="$(python3 - "$INTERACTIVE_NOTE" <<'PY'
import json
import sys
print(json.dumps({"path": sys.argv[1]}))
PY
)"
tuistory -s "$INTERACTIVE_SESSION" close >/dev/null 2>&1 || true
tuistory launch "$BIN_PATH --provider faux --tools read" \
  -s "$INTERACTIVE_SESSION" \
  --cwd "$INTERACTIVE_PROJECT" \
  --cols 140 \
  --rows 36 \
  --env "HOME=$INTERACTIVE_HOME" \
  --env "PI_CODING_AGENT_DIR=$INTERACTIVE_AGENT" \
  --env "PI_FAUX_TOOL_NAME=read" \
  --env "PI_FAUX_TOOL_ARGS_JSON=$INTERACTIVE_ARGS_JSON" \
  --env "PI_FAUX_TOOL_FINAL_RESPONSE=The file says: secret note"
tuistory -s "$INTERACTIVE_SESSION" wait-idle --timeout 8000
tuistory -s "$INTERACTIVE_SESSION" type "what is in the file?"
tuistory -s "$INTERACTIVE_SESSION" press enter
tuistory -s "$INTERACTIVE_SESSION" wait "The file says: secret note" --timeout 8000
tuistory -s "$INTERACTIVE_SESSION" wait-idle --timeout 3000
interactive_snapshot="$(tuistory -s "$INTERACTIVE_SESSION" snapshot --trim)"
printf '%s\n' "$interactive_snapshot" | grep -F "Read $INTERACTIVE_NOTE" >/dev/null
printf '%s\n' "$interactive_snapshot" | grep -F "Read result read:" >/dev/null
printf '%s\n' "$interactive_snapshot" | grep -F "secret note" >/dev/null
printf '%s\n' "$interactive_snapshot" | grep -F "The file says: secret note" >/dev/null
tuistory -s "$INTERACTIVE_SESSION" close >/dev/null 2>&1 || true

log "LEGACY-CROSS-MULTI-PROVIDER multi-provider conversation"
make_case_dirs "multi-provider"
MULTI_AGENT="$TMP_ROOT/multi-provider/agent"
MULTI_HOME="$TMP_ROOT/multi-provider/home"
MULTI_PROJECT="$TMP_ROOT/multi-provider/project"

first_provider_output="$(
  cd "$MULTI_PROJECT"
  env \
    HOME="$MULTI_HOME" \
    PI_CODING_AGENT_DIR="$MULTI_AGENT" \
    PI_FAUX_FORCE="1" \
    PI_FAUX_RESPONSE="I will remember marigold." \
    "$BIN_PATH" --provider openai --print "Remember this token: marigold"
)"
[[ "$first_provider_output" == "I will remember marigold." ]]

second_provider_output="$(
  cd "$MULTI_PROJECT"
  env \
    HOME="$MULTI_HOME" \
    PI_CODING_AGENT_DIR="$MULTI_AGENT" \
    PI_FAUX_FORCE="1" \
    PI_FAUX_RESPONSE="You asked me to remember marigold." \
    "$BIN_PATH" --provider anthropic --print --continue "What token did I ask you to remember?"
)"
[[ "$second_provider_output" == "You asked me to remember marigold." ]]
multi_session_file="$(latest_session_file "$MULTI_PROJECT/.pi/sessions")"
assert_multi_provider_entries "$multi_session_file"

log "LEGACY-CROSS-COMPACTION compaction preserves context"
make_case_dirs "compaction"
COMPACTION_AGENT="$TMP_ROOT/compaction/agent"
COMPACTION_HOME="$TMP_ROOT/compaction/home"
COMPACTION_PROJECT="$TMP_ROOT/compaction/project"
cat > "$COMPACTION_AGENT/settings.json" <<'JSON'
{
  "compaction": {
    "enabled": true,
    "reserveTokens": 0,
    "keepRecentTokens": 8
  }
}
JSON

first_compaction_output="$(
  cd "$COMPACTION_PROJECT"
  env \
    HOME="$COMPACTION_HOME" \
    PI_CODING_AGENT_DIR="$COMPACTION_AGENT" \
    PI_FAUX_CONTEXT_WINDOW="32" \
    PI_FAUX_RESPONSE="Reply about sunrise-lilac with enough filler words to exceed the compact threshold quickly." \
    "$BIN_PATH" --provider faux --print "Remember sunrise-lilac as the first topic with enough filler words to exceed the compact threshold quickly."
)"
[[ "$first_compaction_output" == "Reply about sunrise-lilac with enough filler words to exceed the compact threshold quickly." ]]

second_compaction_output="$(
  cd "$COMPACTION_PROJECT"
  env \
    HOME="$COMPACTION_HOME" \
    PI_CODING_AGENT_DIR="$COMPACTION_AGENT" \
    PI_FAUX_CONTEXT_WINDOW="32" \
    PI_FAUX_RESPONSE="Follow-up reply that keeps sunrise-lilac in the compacted session context." \
    "$BIN_PATH" --provider faux --print --continue "Add more context after sunrise-lilac so the executable must preserve the early topic through compaction."
)"
[[ "$second_compaction_output" == "Follow-up reply that keeps sunrise-lilac in the compacted session context." ]]
compaction_session_file="$(latest_session_file "$COMPACTION_PROJECT/.pi/sessions")"
assert_compaction_summary "$compaction_session_file" "sunrise-lilac"

log "all cross-area flows passed"
