#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_PATH="${PI_BINARY:-$ROOT_DIR/zig-out/bin/pi}"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Binary not found: $BIN_PATH" >&2
  exit 1
fi

if ! command -v tuistory >/dev/null 2>&1; then
  echo "tuistory is required for missing-cwd selector tests" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pi-missing-cwd.XXXXXX")"
SESSION="pi-missing-cwd-$$"

cleanup() {
  tuistory -s "$SESSION" close >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

log() {
  printf '[missing-cwd] %s\n' "$1"
}

snapshot_contains() {
  local snapshot="$1"
  local needle="$2"
  if [[ "$snapshot" != *"$needle"* ]]; then
    printf 'snapshot did not contain expected text: %s\n' "$needle" >&2
    printf '%s\n' "$snapshot" >&2
    exit 1
  fi
}

snapshot_does_not_contain() {
  local snapshot="$1"
  local needle="$2"
  if [[ "$snapshot" == *"$needle"* ]]; then
    printf 'snapshot unexpectedly contained text: %s\n' "$needle" >&2
    printf '%s\n' "$snapshot" >&2
    exit 1
  fi
}

# Builds a minimal session JSONL file at $1 with stored cwd = $2.
write_stub_session() {
  local session_file="$1"
  local stored_cwd="$2"
  local session_id="$3"
  local timestamp
  timestamp="$(python3 - <<'PY'
import datetime
print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))
PY
)"
  python3 - "$session_file" "$stored_cwd" "$session_id" "$timestamp" <<'PY'
import json
import sys
from pathlib import Path

session_file = Path(sys.argv[1])
stored_cwd = sys.argv[2]
session_id = sys.argv[3]
timestamp = sys.argv[4]

session_file.parent.mkdir(parents=True, exist_ok=True)
header = {
    "type": "session",
    "version": 3,
    "id": session_id,
    "timestamp": timestamp,
    "cwd": stored_cwd,
}
with session_file.open("w", encoding="utf-8") as f:
    f.write(json.dumps(header) + "\n")
PY
}

prepare_case() {
  local name="$1"
  local case_dir
  case_dir="$(cd "$TMP_ROOT" && pwd -P)/$name"
  mkdir -p "$case_dir/agent" "$case_dir/home" "$case_dir/launch" "$case_dir/stored" "$case_dir/sessions"
  local session_file="$case_dir/sessions/missing-cwd.jsonl"
  # Canonicalize launch and stored paths so snapshot/header assertions match
  # whatever the CLI resolves them to on macOS (/private/var vs /var symlinks).
  local launch_dir stored_dir
  launch_dir="$(cd "$case_dir/launch" && pwd -P)"
  stored_dir="$(cd "$case_dir/stored" && pwd -P)"
  printf '%s\n' "$launch_dir" >"$case_dir/launch.path"
  printf '%s\n' "$stored_dir" >"$case_dir/stored.path"
  write_stub_session "$session_file" "$stored_dir" "missing-cwd-${name}-$$"
  # Capture session bytes for cancel-path equality assertion.
  cp "$session_file" "$case_dir/missing-cwd.jsonl.before"
  rm -rf "$case_dir/stored"
  printf '%s\n' "$case_dir"
}

launch_pi_with_missing_cwd() {
  local case_dir="$1"
  shift
  local launch_dir="$case_dir/launch"
  local home_dir="$case_dir/home"
  local agent_dir="$case_dir/agent"
  local sessions_dir="$case_dir/sessions"

  tuistory -s "$SESSION" close >/dev/null 2>&1 || true
  tuistory launch "$BIN_PATH --provider faux --continue --session-dir $sessions_dir" \
    -s "$SESSION" \
    --cwd "$launch_dir" \
    --cols 100 \
    --rows 24 \
    --env "HOME=$home_dir" \
    --env "PI_CODING_AGENT_DIR=$agent_dir" \
    --env "PI_FAUX_RESPONSE=ok" \
    "$@"
  tuistory -s "$SESSION" wait-idle --timeout 8000
}

verify_session_unchanged() {
  local case_dir="$1"
  local session_file="$case_dir/sessions/missing-cwd.jsonl"
  local before="$case_dir/missing-cwd.jsonl.before"
  if ! cmp -s "$before" "$session_file"; then
    printf 'session file mutated unexpectedly\n' >&2
    diff "$before" "$session_file" >&2 || true
    exit 1
  fi
}

log "case: prompt is rendered as a TUI selector"
prompt_case_dir="$(prepare_case prompt)"
prompt_launch_path="$(cat "$prompt_case_dir/launch.path")"
prompt_stored_path="$(cat "$prompt_case_dir/stored.path")"
launch_pi_with_missing_cwd "$prompt_case_dir"
prompt_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
snapshot_contains "$prompt_snapshot" "Session cwd not found"
snapshot_contains "$prompt_snapshot" "cwd from session file does not exist"
snapshot_contains "$prompt_snapshot" "$prompt_stored_path"
snapshot_contains "$prompt_snapshot" "continue in current cwd"
snapshot_contains "$prompt_snapshot" "$prompt_launch_path"
snapshot_contains "$prompt_snapshot" "Continue"
snapshot_contains "$prompt_snapshot" "Cancel"
snapshot_contains "$prompt_snapshot" "Up/Down move"
snapshot_does_not_contain "$prompt_snapshot" "[Continue]/Cancel? [Y/n]"
verify_session_unchanged "$prompt_case_dir"
tuistory -s "$SESSION" close >/dev/null 2>&1 || true

log "case: cancel exits without mutating the session file"
cancel_case_dir="$(prepare_case cancel)"
launch_pi_with_missing_cwd "$cancel_case_dir"
tuistory -s "$SESSION" press down
tuistory -s "$SESSION" wait-idle --timeout 3000
tuistory -s "$SESSION" press enter
tuistory -s "$SESSION" wait "Resume cancelled" --timeout 5000
cancel_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
snapshot_contains "$cancel_snapshot" "Resume cancelled"
verify_session_unchanged "$cancel_case_dir"
tuistory -s "$SESSION" close >/dev/null 2>&1 || true

log "case: escape on the prompt cancels and exits"
escape_case_dir="$(prepare_case escape)"
launch_pi_with_missing_cwd "$escape_case_dir"
tuistory -s "$SESSION" press escape
tuistory -s "$SESSION" wait "Resume cancelled" --timeout 5000
escape_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
snapshot_contains "$escape_snapshot" "Resume cancelled"
verify_session_unchanged "$escape_case_dir"
tuistory -s "$SESSION" close >/dev/null 2>&1 || true

log "case: continue confirms the launch cwd and bootstraps the interactive UI"
continue_case_dir="$(prepare_case continue)"
continue_launch_path="$(cat "$continue_case_dir/launch.path")"
launch_pi_with_missing_cwd "$continue_case_dir"
# Default selection is Continue (index 0).
tuistory -s "$SESSION" press enter
tuistory -s "$SESSION" wait "Welcome to pi" --timeout 8000
continue_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
snapshot_contains "$continue_snapshot" "Welcome to pi"
snapshot_contains "$continue_snapshot" "Model:"
# The continue path should not show the missing-cwd selector after the user
# confirms.
snapshot_does_not_contain "$continue_snapshot" "Session cwd not found"
snapshot_does_not_contain "$continue_snapshot" "Resume cancelled"
tuistory -s "$SESSION" close >/dev/null 2>&1 || true

log "all missing-cwd selector flows passed"
