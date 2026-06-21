#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

fail=0

check_no_match() {
  local scope="$1"
  local pattern="$2"
  local label="$3"

  if rg -n --glob '*.zig' "$pattern" "$scope" >/tmp/pi-import-boundary.$$ 2>/dev/null; then
    echo "import-boundary violation: $label"
    cat /tmp/pi-import-boundary.$$
    fail=1
  fi
  rm -f /tmp/pi-import-boundary.$$
}

check_no_match "src/tui" '@import\(".*coding_agent|@import\("\.\./coding_agent|@import\("\.\./\.\./coding_agent' 'tui must not import coding_agent'
check_no_match "src/coding_agent/tools" '@import\("\.\./interactive_mode|@import\("interactive_mode' 'tools must not import interactive_mode'
check_no_match "src/coding_agent/extensions" '@import\("\.\./tui|@import\("\.\./\.\./tui|@import\("tui' 'extensions must not import tui'

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo 'import-boundaries: ok'
