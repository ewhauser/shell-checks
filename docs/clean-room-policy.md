# Clean-Room Policy

## Purpose

This repository stores internally authored shell snippets that are expected to trigger selected compatibility codes when checked with the ShellCheck binary. The repository documents an independent authoring process rather than a textual match to ShellCheck materials.

## Scope of Claim

This repository's clean-room claim is scoped to ShellCheck-origin materials. It does not claim isolation from all third-party shell scripts, public shell projects, or general shell references.

Non-ShellCheck shell scripts from unrelated projects may be used during discovery, corpus scanning, or hint generation to identify numeric compatibility codes or the kind of construct that triggers a code. Those materials are discovery inputs only. Committed `rules/` and `examples/` must still be independently authored and must not copy ShellCheck materials or third-party snippets verbatim.

## Approved Inputs

- Shell language manuals, specifications, and semantic notes
- Files authored inside this repository
- Non-ShellCheck third-party shell scripts or corpus-derived hints used to identify numeric codes or likely triggering constructs
- ShellCheck binary runs used as a black-box oracle for numeric compatibility codes
- Provenance records committed with each artifact

## Prohibited Inputs

- ShellCheck source code
- ShellCheck wiki pages or documentation examples
- Reused diagnostic wording from ShellCheck materials
- Verbatim copying of third-party corpus snippets into committed `rules/` or `examples/`
- Raw ShellCheck output copied into committed repository files

## Required Artifact Set

Each new `SH-*` addition must ship in one change with:

- a rule spec under `rules/`
- a violating script under `examples/`
- a numeric compatibility mapping under `mappings/`
- an artifact provenance record under `provenance/artifacts/`
- an AI session record under `provenance/ai-sessions/` when AI assistance was used

## Shared Index Files

`mappings/shellcheck.yaml` and `discovery/known-codes.yaml` are shared indexes that grow with every addition. They are **not** tracked in individual artifact `files` lists or session `generated_files` lists because their content changes with every commit, which would immediately invalidate all prior artifact hashes. Their integrity is maintained at the repository level through version control.

## Session Size

Each AI session should generate at most 15 artifact-specific files (roughly 5 `SH-*` bundles). Keeping sessions small ties each provenance record to a focused authoring task rather than a bulk generation run. Existing sessions that predate this limit are grandfathered.

AI session `generated_files` entries should list only artifact-specific outputs under `rules/`, `examples/`, and `provenance/artifacts/`. Mutable repository infrastructure such as `README.md`, `docs/`, `discovery/`, and `scripts/` is intentionally excluded so later maintenance does not invalidate historical session hashes.

For sessions created after prompt-artifact recording was introduced, record the exact prompt input files under `provenance/prompts/<session_id>/` and list them in the session record's `prompt_files` field. Those prompt artifacts are provenance inputs, not generated outputs, so they are intentionally excluded from `generated_files`.

## Authoring Rules

- Write all summaries, rationales, comments, and future diagnostics from scratch.
- Keep examples narrow enough that the mapped compatibility code is clearly explained and extra diagnostics are minimized.
- Companion parser or context diagnostics are acceptable when they arise from the same triggering construct and the mapped compatibility code remains present.
- Compatibility codes may be referenced as bare numbers or `SC1234`-style identifiers in project-authored outputs.
- If a committed example needs a `# shellcheck disable=` pragma, use numeric codes only because that pragma format is numeric.
- Do not copy ShellCheck text or third-party corpus snippets verbatim into committed authored artifacts.
- Do not commit copied output from oracle runs. Oracle behavior must remain rerunnable.

## Discovery Rules

- AI-assisted discovery may use the local shell and ShellCheck binary as an oracle to search for new numeric compatibility codes.
- Discovery may also use non-ShellCheck third-party shell scripts or repository-generated corpus hints to identify numeric codes or likely triggering constructs.
- Discovery prompts must explicitly forbid use of ShellCheck source, wiki pages, documentation examples, and reused diagnostic wording.
- Discovery prompts should query prior coverage through `scripts/check-codes.sh` or an equivalently narrow interface rather than embedding the full known-code ledger in prompt text.
- Discovery outputs may record numeric codes, fresh candidate snippets, and original semantic notes only.
- Discovery material must not be promoted into `rules/` or end-user documentation without a separate clean-room authoring phase.

## Provenance Model

The repository keeps two provenance layers:

- AI session records describe the task summary, allowed source classes, recorded prompt artifacts, and hashes tied to the authored output bundle.
- Artifact records describe the semantic basis, file hashes, oracle command, and clean-room declaration for each `SH-*` addition.

`prompt_sha256` is the SHA-256 digest of the sorted prompt file manifest written as `path<TAB>sha256` for each recorded prompt artifact. Legacy sessions that predate prompt-artifact recording are grandfathered and may still use the older metadata-based prompt hash.

`output_sha256` is the SHA-256 digest of the sorted generated file manifest written as `path<TAB>sha256`.

## Verification

Use `scripts/verify-oracle.sh` to confirm that a seed example produces the mapped numeric code in the declared shell mode. Use `--strict` to report extra codes; those warnings are review signals, not automatic failures.

Use `scripts/verify-provenance.sh` to confirm that provenance files are complete, file hashes still match current contents, shared index files are not tracked in per-artifact or per-session manifests, and corpus-derived sessions consistently declare the corpus source class.
