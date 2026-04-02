# Issue-Discovered Artifact Creation

You are working in a clean-room shell linting project. GitHub community issues from the ShellCheck issue tracker have been mined for references to numeric SC codes. These issues are community-authored (not ShellCheck source, documentation, or wiki content) and contain shell snippets, error descriptions, and behavioral observations that can serve as weak contextual hints for independently authoring artifact bundles.

**Important**: The clean-room restriction in this repository is scoped to ShellCheck-origin materials. GitHub issue content is community-authored and is not protected under the project's license per GitHub's Terms of Service. You may use issue-derived hints (shell snippets, behavioral descriptions) to inform your understanding of what construct triggers a code, but your committed examples and rule text must still be independently authored and must not copy ShellCheck diagnostic wording or issue text verbatim.

## Hard Provenance Rules

These rules exist to maintain an evidence trail for independent authorship. Every artifact must be traceable to shell semantics knowledge and oracle runs, never to ShellCheck's own documentation or source.

- Do not read or rely on ShellCheck source code.
- Do not read or rely on ShellCheck wiki pages.
- Do not read or rely on ShellCheck documentation examples.
- Do not reuse ShellCheck diagnostic wording.
- Do not copy or adapt example snippets from ShellCheck materials.
- Do not browse the web for ShellCheck guidance.
- Do not copy shell snippets from issue text into committed `rules/` or `examples/` verbatim. Use them as hints to understand the semantic area, then write your own minimal example.
- Treat the ShellCheck binary as an oracle for numeric codes only.
- Use `mappings/shellcheck.yaml` and `discovery/known-codes.yaml` as the authoritative compatibility ledger.
- Compatibility identifiers may appear as bare numbers or `SC1234`, but do not reuse ShellCheck diagnostic wording.
- If you need a `# shellcheck disable=` pragma in an example script, use numeric codes only.

## Allowed Inputs

- Files already present in this repository
- General shell semantics knowledge
- Fresh shell snippets authored during this session
- Local shell commands and `shellcheck` runs
- Community-authored issue text from `issues/` (as weak contextual hints only, not to be copied verbatim)
- Issue-extracted hints from `discovery/issue-hints.yaml`

## Using Issue Hints Effectively

The `discovery/issue-hints.yaml` file contains extracted hints for each undiscovered code:
- **snippets**: Community shell snippets from issues that triggered the code. Use these to understand what *kind* of construct is involved, then write your own minimal example from scratch.
- **hint**: A one-line contextual clue about the code's purpose. This often reveals the semantic category (e.g., "unused variable", "POSIX portability", "quoting").

For deeper context on a specific code, read the full issue files listed under `issues:` in the hints file. Look for:
- The **reporter's description** of what they expected vs. what happened
- Any **shell snippets** that demonstrate the behavior
- **Comments** that discuss the semantic rule

## Dataflow Rules

Not all codes can be triggered by a single isolated construct. Some require dataflow analysis — reasoning about relationships across multiple statements, such as how values flow through assignments, how control flow determines which statements are reachable, or how a declaration on one line affects the interpretation of a reference on another. When a single-construct snippet does not trigger a new code, consider whether the oracle might be checking a cross-statement property, and build examples with multiple interacting statements that set up that relationship.

## Target Codes

The following codes were discovered via GitHub issue mining and need artifact bundles:

{{NEW_CODES_LIST}}

## Artifact Creation

For each target code, create the full artifact bundle. The project assigns sequential IDs starting from `{{NEXT_RB_NUM}}` for rule IDs and `{{NEXT_SESSION_ID}}` for the session record.

If you are creating N artifact bundles, use IDs SH-{{NEXT_RB_NUM}}, SH-{{NEXT_RB_NUM_PLUS_1}}, ... and create only one AI session record that lists all generated files.

### Strategy for each code

1. Read the hint and any relevant issue files to understand what semantic area this code covers.
2. From shell semantics knowledge (informed by hints), reason about what construct triggers this code.
3. Write a minimal fresh shell snippet and test it with the oracle.
4. Run `./scripts/shellcheck-codes-only.sh -s <shell> <file>` to confirm the code.
5. If the snippet triggers the wrong code or too many extra codes, adjust until the target code is present and extra diagnostics are minimized.
6. If you cannot trigger a code after reasonable effort, skip it and move to the next.

### Step 1: Create the example script

Write a minimal shell script under `examples/` that triggers the target compatibility code. The file should be named by the RB number (e.g., `examples/{{NEXT_EXAMPLE_NUM}}.sh`). Keep it short and narrow, and minimize extra diagnostics.

Format:
```
#!/bin/sh
<minimal code that triggers the finding>
```

Inspect the numeric codes it produces by running:
```
./scripts/shellcheck-codes-only.sh -s <shell> examples/<NNN>.sh
```
Prefer examples that emit only the target code, but companion parser or context diagnostics are acceptable when they are tightly coupled to the same construct.

### Step 2: Create the rule spec

Write a rule spec under `rules/` in your own words. Do not reuse ShellCheck diagnostic wording.

Format (`rules/SH-<NNN>.yaml`):
```yaml
id: SH-<NNN>
name: <short-kebab-case-name>
summary: <one-sentence description of the issue, in your own words>
shells:
  - <sh|bash|dash|ksh>
example: examples/<NNN>.sh
rationale: <one-sentence recommendation, in your own words>
requires_dataflow: <true only if the rule requires cross-statement analysis; omit otherwise>
```

### Step 3: Update the mappings file

Append a new entry to `mappings/shellcheck.yaml` under the existing `mappings:` list.

Format for each new entry:
```yaml
  - sh_id: SH-<NNN>
    example: examples/<NNN>.sh
    shellcheck_code: <numeric code>
    shells:
      - <sh|bash|dash|ksh>
    shellcheck_version: {{SHELLCHECK_VERSION}}
```

Preserve the existing file structure and append only the new entries.

### Step 4: Update the known-codes ledger

Append new entries to `discovery/known-codes.yaml` under the existing `known_codes:` list for each newly discovered code.

Format for each new entry:
```yaml
  - shellcheck_code: <numeric code>
    status: covered
    shells:
      - <shell>
    rationale: "<short explanation of why this code is now covered>"
    sources:
      - mappings/SH-<NNN>
```

Important: Always wrap the `rationale` value in double quotes. Unquoted values that contain backticks, colons, or other special characters will cause YAML parse errors.

If you need to confirm whether a target code is already recorded before appending, run `./scripts/check-codes.sh <code>`.

### Step 5: Create the artifact provenance record

For each SH-* addition, create `provenance/artifacts/SH-<NNN>.yaml`.

The `files` list must include the rule spec and example only. `mappings/shellcheck.yaml` and `discovery/known-codes.yaml` are shared indexes and are not tracked in per-artifact manifests. Compute SHA-256 for each tracked file after writing it:
```
shasum -a 256 <file> | awk '{print $1}'
```

Format:
```yaml
artifact_id: SH-<NNN>
created_at: {{TODAY}}
files:
  - path: rules/SH-<NNN>.yaml
    sha256: <computed hash>
  - path: examples/<NNN>.sh
    sha256: <computed hash>
source_basis:
  - <one sentence describing the shell semantics that motivated this snippet>
  - <one sentence describing how the example was authored, reduced, and checked for extra diagnostics>
ai_sessions:
  - {{NEXT_SESSION_ID}}
oracle:
  tool: shellcheck
  version: {{SHELLCHECK_VERSION}}
  command: shellcheck --norc -s <shell> -f json1 examples/<NNN>.sh
  expected_code: <numeric code>
clean_room_statement: >-
  This artifact set was authored from shell semantics and local oracle
  runs without reusing ShellCheck source, wiki text, or example snippets.
  The numeric code was initially identified via GitHub issue mining of
  community-authored content, but the example script was independently authored.
```

### Step 6: Create the AI session record

Create exactly one session record at `provenance/ai-sessions/{{NEXT_SESSION_ID}}.yaml` that covers all artifacts created in this run.

The `generated_files` list must include every artifact-specific file you created or modified. Do not include shared index files such as `mappings/shellcheck.yaml` or `discovery/known-codes.yaml`.

The `prompt_files` list must include the exact prompt artifact shown to the model for this workflow:
```yaml
prompt_files:
  - {{PROMPT_FILE_PATH}}
```

`prompt_sha256` is the SHA-256 digest of a sorted prompt-file manifest where each line is `<relative-path>\t<sha256>` for one recorded prompt file. `output_sha256` is the SHA-256 digest of the same kind of manifest for `generated_files`.

When you first write the session record, set both hashes to a 64-zero placeholder. After all files are written, run:
```sh
ruby scripts/reconcile-provenance-hashes.rb "$PWD"
```
That command will replace the placeholder hashes with the canonical values derived from `prompt_files` and `generated_files`.

Use these field values:
```yaml
session_id: {{NEXT_SESSION_ID}}
date: {{TODAY}}
tool: codex
model: {{MODEL}}
task_summary: "Create clean-room artifact bundles for issue-discovered ShellCheck codes."
allowed_source_classes:
  - shell language manuals and semantic notes
  - internally authored repository files
  - Community-authored GitHub issue content used as weak contextual hints for identifying candidate compatibility codes
  - shellcheck binary behavior observed through command-line runs
prompt_files:
  - {{PROMPT_FILE_PATH}}
prompt_sha256: 0000000000000000000000000000000000000000000000000000000000000000
output_sha256: 0000000000000000000000000000000000000000000000000000000000000000
```

### Step 7: Run verification

After creating all files, run the verification scripts to confirm everything is correct:

```sh
ruby scripts/reconcile-provenance-hashes.rb "$PWD"
./scripts/verify-oracle.sh --strict
./scripts/verify-provenance.sh
```

If either script fails, read the error messages, fix the issues, rerun `reconcile-provenance-hashes.rb`, and then rerun verification.
