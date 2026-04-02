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

## Issue-Based Discovery

The `issues/` directory contains community-authored issues from the ShellCheck GitHub issue tracker. These are not ShellCheck source, documentation, or wiki content — they are user-submitted bug reports and feature requests that reference SC codes and include shell snippets.

GitHub's Terms of Service specify that community content is not protected under the project's license unless the project specifically says otherwise, and ShellCheck does not.

### Extracting Hints

Run `./scripts/extract-issue-hints.sh` to generate `discovery/issue-hints.yaml`, which maps undiscovered SC codes to:
- Issue numbers that reference them
- Community-authored shell snippets from those issues
- Semantic hints about what the code detects

### Using Issue Hints for Artifact Creation

Use the `discovery/issue-artifact-template.md` template when creating artifacts from issue-discovered codes. The template follows the same provenance rules as the GitHub search template but allows issue content as weak contextual hints.

The same clean-room rules apply: committed examples and rule text must be independently authored. Issue content informs your understanding but must not be copied verbatim.
