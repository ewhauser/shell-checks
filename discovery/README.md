# Discovery Lane

This directory is for AI-assisted discovery of new numeric compatibility codes. It is intentionally narrower than the rule-authoring path.

The clean-room restriction in this repository is scoped to ShellCheck-origin materials. Discovery may use unrelated third-party shell corpora or repository-generated corpus hints to identify numeric codes or infer what construct triggered a code. Those inputs are not ShellCheck IP, but committed `rules/` and `examples/` must still be independently authored and must not copy ShellCheck text or third-party snippets verbatim.

## Allowed Outputs

- numeric compatibility codes
- fresh shell snippets authored during discovery
- original notes about shell semantics or search strategy
- original internal rationale for why a known code is already covered

## Prohibited Outputs

- copied ShellCheck rule prose
- copied ShellCheck examples
- copied ShellCheck diagnostic wording
- rule descriptions promoted directly into `rules/`

## Workflow

1. Render the current discovery prompt with `./scripts/render-discovery-prompt.sh`.
2. Run an AI session that has shell access but follows the prompt's provenance rules.
3. Use the local `shellcheck` binary as a black-box oracle through `./scripts/shellcheck-codes-only.sh` and treat message text as non-authoritative.
4. Check candidate codes with `./scripts/check-codes.sh` instead of reviewing the full known-code ledger during discovery.
5. If the AI finds a new numeric code, record it in `discovery/known-codes.yaml` before starting another search pass, or hand the result to a follow-on clean-room authoring phase.

Discovery by itself does not satisfy the repository's authored artifact requirements. Some repository workflows chain discovery directly into a follow-on clean-room authoring phase, but the committed rule and example text must still be written independently.
