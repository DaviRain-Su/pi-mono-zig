#!/usr/bin/env sh
set -eu

# Consume initialize frame, then expose one deterministic extension command.
IFS= read -r _init || exit 1
printf '%s\n' '{"type":"ready"}'
printf '%s\n' '{"type":"register_command","name":"extension-ui-smoke","description":"Exercise extension UI bridge","extensionPath":"ui-bridge-fixture.sh"}'

state="idle"
while IFS= read -r line; do
  case "$state:$line" in
    idle:*'"type":"command"'*'"name":"extension-ui-smoke"'*)
      printf '%s\n' '{"type":"extension_ui_request","id":"ui-smoke-select","method":"select","responseRequired":true,"title":"Pick extension value","options":["alpha","beta"],"timeout":5000}'
      state="select"
      ;;
    select:*'"type":"extension_ui_response"'*'"id":"ui-smoke-select"'*)
      printf '%s\n' '{"type":"extension_ui_request","id":"ui-smoke-input","method":"input","responseRequired":true,"title":"Extension input","placeholder":"value","timeout":5000}'
      state="input"
      ;;
    input:*'"type":"extension_ui_response"'*'"id":"ui-smoke-input"'*)
      printf '%s\n' '{"type":"extension_ui_request","id":"ui-smoke-editor-text","method":"set_editor_text","text":"extension editor text"}'
      printf '%s\n' '{"type":"extension_ui_request","id":"ui-smoke-thinking-label","method":"setHiddenThinkingLabel","label":"Hidden extension thinking"}'
      printf '%s\n' '{"type":"extension_ui_request","id":"ui-smoke-custom","method":"send_custom_message","customType":"extension.ui.smoke","content":"extension custom result"}'
      state="done"
      ;;
    *'"type":"shutdown"'*)
      printf '%s\n' '{"type":"shutdown_complete"}'
      exit 0
      ;;
  esac
done
