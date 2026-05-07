# Changelog

## [Unreleased]

### Changed

- Replaced the Zig interactive missing stored-cwd stderr/stdin prompt with a full TUI Continue/Cancel selector that mirrors the TypeScript `ExtensionSelectorComponent` flow used by `promptForMissingSessionCwd`, with tuistory coverage for prompt rendering, cancel, escape, and continue paths. Cancel exits without mutating the session file; continue persists the launch cwd only after explicit confirmation.

### Fixed

- Improved Zig TUI day/night theme contrast, exposed `/theme` in slash command suggestions, and left terminal mouse reporting off by default so native text selection/copy works while bracketed paste remains enabled.
- Fixed blank Chinese IME commits in the Zig interactive TUI input box on Linux Ghostty + Fcitx by suppressing Kitty keyboard protocol enablement for Ghostty while preserving other terminals.
- The Zig missing stored-cwd preflight now runs before `runtime_prep.prepareCliRuntime` in non-interactive and interactive resume/open flows. Runtime config, resource bundle, context file, system prompt, provider auth, and tool construction failures can no longer preempt the missing-cwd diagnostic or the Continue/Cancel TUI selector. The early Continue path is recorded so the deeper interactive bootstrap does not prompt twice, and `readSessionHeader` now uses a bounded streaming first-line read instead of loading the entire session file.
