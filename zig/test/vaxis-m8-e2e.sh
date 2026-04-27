#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_PATH="${PI_BINARY:-$ROOT_DIR/zig-out/bin/pi}"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Binary not found: $BIN_PATH" >&2
  exit 1
fi

if ! command -v tuistory >/dev/null 2>&1; then
  echo "tuistory is required for vaxis M8 integration tests" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pi-vaxis-m8.XXXXXX")"
SESSION="pi-vaxis-m8-$$"

cleanup() {
  tuistory -s "$SESSION" close >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

log() {
  printf '[vaxis-m8] %s\n' "$1"
}

make_case_dirs() {
  local name="$1"
  mkdir -p "$TMP_ROOT/$name/agent" "$TMP_ROOT/$name/home" "$TMP_ROOT/$name/project"
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

launch_interactive() {
  local project="$1"
  local home="$2"
  local agent="$3"
  shift 3
  tuistory -s "$SESSION" close >/dev/null 2>&1 || true
  tuistory launch "$BIN_PATH --provider faux --tools read" \
    -s "$SESSION" \
    --cwd "$project" \
    --cols 120 \
    --rows 32 \
    --env "HOME=$home" \
    --env "PI_CODING_AGENT_DIR=$agent" \
    "$@"
  tuistory -s "$SESSION" wait-idle --timeout 8000
}

log "interactive chat, tools, selectors, slash commands, paste, queue, and error paths"
make_case_dirs "interactive"
PROJECT="$TMP_ROOT/interactive/project"
HOME_DIR="$TMP_ROOT/interactive/home"
AGENT_DIR="$TMP_ROOT/interactive/agent"
NOTE="$PROJECT/note.txt"
printf 'm8 secret note' > "$NOTE"
ARGS_JSON="$(python3 - "$NOTE" <<'PY'
import json
import sys
print(json.dumps({"path": sys.argv[1]}))
PY
)"

launch_interactive "$PROJECT" "$HOME_DIR" "$AGENT_DIR" \
  --env "PI_FAUX_TOOL_NAME=read" \
  --env "PI_FAUX_TOOL_ARGS_JSON=$ARGS_JSON" \
  --env "PI_FAUX_TOOL_FINAL_RESPONSE=# M8 assistant response\n\n- tool path rendered\n\nThe file says: m8 secret note"

startup_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
snapshot_contains "$startup_snapshot" "> "
snapshot_contains "$startup_snapshot" "Model:"

tuistory -s "$SESSION" type "what is in the file?"
tuistory -s "$SESSION" press enter
tuistory -s "$SESSION" wait "The file says: m8 secret note" --timeout 10000
chat_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
snapshot_contains "$chat_snapshot" "Read "
snapshot_contains "$chat_snapshot" "Read result read:"
snapshot_contains "$chat_snapshot" "m8 secret note"
snapshot_contains "$chat_snapshot" "M8 assistant response"
tuistory -s "$SESSION" close >/dev/null 2>&1 || true

launch_interactive "$PROJECT" "$HOME_DIR" "$AGENT_DIR" \
  --env "PI_FAUX_RESPONSE=selector smoke"
tuistory -s "$SESSION" press ctrl p
tuistory -s "$SESSION" wait "Model selector" --timeout 5000
model_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
snapshot_contains "$model_snapshot" "Model selector"
snapshot_contains "$model_snapshot" "faux"
tuistory -s "$SESSION" close >/dev/null 2>&1 || true

launch_interactive "$PROJECT" "$HOME_DIR" "$AGENT_DIR" \
  --env "PI_FAUX_RESPONSE=session selector smoke"
tuistory -s "$SESSION" press ctrl s
tuistory -s "$SESSION" wait "Session selector" --timeout 5000
session_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
snapshot_contains "$session_snapshot" "Session selector"
tuistory -s "$SESSION" close >/dev/null 2>&1 || true

launch_interactive "$PROJECT" "$HOME_DIR" "$AGENT_DIR" \
  --env "PI_FAUX_RESPONSE=hotkeys smoke"
tuistory -s "$SESSION" type "/hotkeys"
tuistory -s "$SESSION" press enter
tuistory -s "$SESSION" press enter
tuistory -s "$SESSION" wait "Keyboard shortcuts" --timeout 5000
hotkeys_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
snapshot_contains "$hotkeys_snapshot" "Keyboard shortcuts"
tuistory -s "$SESSION" close >/dev/null 2>&1 || true

launch_interactive "$PROJECT" "$HOME_DIR" "$AGENT_DIR" \
  --env "PI_FAUX_RESPONSE=queue paste error smoke"
tuistory -s "$SESSION" type "queued follow-up from m8"
tuistory -s "$SESSION" press alt enter
tuistory -s "$SESSION" wait "queued follow-up" --timeout 5000
queue_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
snapshot_contains "$queue_snapshot" "queued follow-up"
snapshot_contains "$queue_snapshot" "Alt+⏎ queue"

tuistory -s "$SESSION" press ctrl v
tuistory -s "$SESSION" wait "clipboard" --timeout 8000
paste_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
snapshot_contains "$paste_snapshot" "clipboard"

tuistory -s "$SESSION" type "/not-a-real-command"
tuistory -s "$SESSION" press enter
tuistory -s "$SESSION" press enter
tuistory -s "$SESSION" wait "Unknown slash command" --timeout 5000
error_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
snapshot_contains "$error_snapshot" "Unknown slash command"
tuistory -s "$SESSION" close >/dev/null 2>&1 || true

log "interactive compaction command"
make_case_dirs "compaction"
COMPACT_PROJECT="$TMP_ROOT/compaction/project"
COMPACT_HOME="$TMP_ROOT/compaction/home"
COMPACT_AGENT="$TMP_ROOT/compaction/agent"
cat > "$COMPACT_AGENT/settings.json" <<'JSON'
{
  "compaction": {
    "enabled": true,
    "reserveTokens": 0,
    "keepRecentTokens": 8
  }
}
JSON
launch_interactive "$COMPACT_PROJECT" "$COMPACT_HOME" "$COMPACT_AGENT" \
  --env "PI_FAUX_CONTEXT_WINDOW=32" \
  --env "PI_FAUX_RESPONSE=compacted m8 context"
tuistory -s "$SESSION" type "/compact preserve m8 topic"
tuistory -s "$SESSION" press enter
tuistory -s "$SESSION" press enter
tuistory -s "$SESSION" wait "Nothing to compact yet" --timeout 10000
compact_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
snapshot_contains "$compact_snapshot" "Nothing to compact yet"
tuistory -s "$SESSION" close >/dev/null 2>&1 || true

log "cross-terminal environment smoke profiles"
for profile in \
  "generic-xterm|xterm-256color||XTERM" \
  "ghostty|xterm-ghostty|ghostty|GHOSTTY" \
  "wezterm|xterm-256color|WezTerm|WEZTERM" \
  "iterm2|xterm-256color|iTerm.app|ITERM" \
  "kitty|xterm-kitty|kitty|KITTY" \
  "alacritty|alacritty|Alacritty|ALACRITTY"
do
  IFS='|' read -r name term term_program badge <<<"$profile"
  make_case_dirs "terminal-$name"
  T_PROJECT="$TMP_ROOT/terminal-$name/project"
  T_HOME="$TMP_ROOT/terminal-$name/home"
  T_AGENT="$TMP_ROOT/terminal-$name/agent"
  SCROLL_RESPONSE="$(python3 - "$name" <<'PY'
import sys
name = sys.argv[1]
for i in range(1, 46):
    print(f"{name} scroll line {i:02d}")
    print()
print(f"{name} scroll tail")
PY
)"
  launch_interactive "$T_PROJECT" "$T_HOME" "$T_AGENT" \
    --env "TERM=$term" \
    --env "TERM_PROGRAM=$term_program" \
    --env "PI_FAUX_RESPONSE=$SCROLL_RESPONSE"
  tuistory -s "$SESSION" type "$name smoke"
  tuistory -s "$SESSION" press enter
  tuistory -s "$SESSION" wait "$name scroll tail" --timeout 8000
  terminal_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
  snapshot_contains "$terminal_snapshot" "$name scroll tail"
  snapshot_contains "$terminal_snapshot" "$badge"
  tuistory -s "$SESSION" scroll --x 10 --y 6 up 6
  tuistory -s "$SESSION" wait-idle --timeout 3000
  scrolled_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
  snapshot_contains "$scrolled_snapshot" "↓ more"
  tuistory -s "$SESSION" press ctrl g
  tuistory -s "$SESSION" wait-idle --timeout 3000
  tail_snapshot="$(tuistory -s "$SESSION" snapshot --trim)"
  snapshot_contains "$tail_snapshot" "$name scroll tail"
  tuistory -s "$SESSION" close >/dev/null 2>&1 || true
done

log "all vaxis M8 tuistory flows passed"
