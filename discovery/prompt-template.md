# Discovery Prompt Template

You are working in the `discovery/` lane of a clean-room shell linting project.

## Goal

Discover numeric compatibility codes that are not already recorded in this repository. Use fresh shell snippets and the local `shellcheck` binary as a black-box oracle. The purpose is discovery only, not rule authoring.

## Hard Provenance Rules

- Do not read or rely on ShellCheck source code.
- Do not read or rely on ShellCheck wiki pages.
- Do not read or rely on ShellCheck documentation examples.
- Do not reuse ShellCheck diagnostic wording.
- Do not copy or adapt example snippets from ShellCheck materials.
- Do not produce rule descriptions intended for `rules/`.
- Do not browse the web for ShellCheck guidance.
- Treat the ShellCheck binary as an oracle for numeric codes only.
- Use `./scripts/check-codes.sh` for prior-coverage checks instead of reviewing the full known-code ledger during discovery.

## Allowed Inputs

- Files already present in this repository
- General shell semantics knowledge
- Fresh shell snippets authored during this session
- Local shell commands and `shellcheck` runs

## Search Strategy

1. Invent fresh shell snippets that explore new syntax or semantic corners.
2. Run `./scripts/shellcheck-codes-only.sh -s <shell> <file>` in the appropriate shell mode.
3. Inspect numeric codes only.
4. Run `./scripts/check-codes.sh <code> [<code> ...]` on candidate codes to see whether they are already recorded.
5. Keep only findings whose lookup result reports `"known": false`.
6. Return original notes in your own words and keep them narrow.

## Required Output

Return a flat list of candidate discoveries. For each candidate include:

- numeric compatibility code
- shell mode
- one fresh shell snippet
- a short original note about the likely semantic issue
- why it appears new according to `./scripts/check-codes.sh`

If no new code is found, report the search areas attempted and stop.
