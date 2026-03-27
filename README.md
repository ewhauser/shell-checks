# shell-checks

This repository contains clean-room-authored shell snippets that are expected to trigger selected compatibility findings when checked with the ShellCheck binary. The project is organized to preserve an evidence trail for independent creation rather than to mirror ShellCheck source, wording, or documentation examples.

The repository's clean-room claim is scoped to ShellCheck-origin materials. Discovery may use unrelated third-party shell scripts or corpus-derived hints to identify numeric compatibility codes or likely triggering constructs, but committed `rules/` and `examples/` must still be independently authored and must not reuse ShellCheck source, wiki text, diagnostic wording, or documentation examples.

## Why

ShellCheck is a great tool but it's GPL licensed and written in Haskell. I'm planning on rewriting it but don't want to come up with my own rule corpus from scratch so that users can have a drop in replacement.

We've currently discovered 353 codes out of 520 (according to ChatGPT) using the following methods:

1) Using a large corpus of shell scripts from GitHub and running ShellCheck on them
2) Brute force search with an LLM

## Repository Layout

- `rules/` holds internal `SH-*` rule specs written in project wording.
- `examples/` holds violating shell scripts paired with those rules.
- `mappings/` holds numeric compatibility mappings to the ShellCheck oracle.
- `discovery/` holds numeric discovery state and prompt material for AI-assisted rule discovery.
- `provenance/` holds AI session records and artifact provenance manifests.
- `scripts/` holds verification entrypoints.
- `docs/clean-room-policy.md` defines the repository's clean-room and provenance rules.

## Seed Scaffold

The first seed artifact is `SH-001`, paired with `examples/001.sh`. Its rule spec, compatibility mapping, and provenance record show the minimum bundle expected for any new addition.

## Expected Workflow

1. Author a new rule spec and example from approved sources only.
2. Add or update the numeric compatibility mapping under `mappings/`.
3. Record provenance for the artifact and any AI session that produced it.
4. Run both verification scripts before committing.

## Discovery

Use the discovery lane to find new numeric compatibility codes without importing ShellCheck prose into the rule-authoring path.

```sh
./scripts/render-discovery-prompt.sh
```

The rendered prompt includes strict provenance constraints and tells the model to query candidate codes with `./scripts/check-codes.sh` instead of being handed the full known-code ledger up front. Discovery output should stay in terms of numeric codes, fresh shell snippets, and original semantic notes.

## Verification

```sh
./scripts/verify-oracle.sh
./scripts/verify-provenance.sh
```

`verify-oracle.sh` checks that each example produces the mapped numeric compatibility code in the declared shell mode. Use `./scripts/verify-oracle.sh --strict` to surface extra codes so noisy examples can be reviewed.

`verify-provenance.sh` checks that provenance records are complete, tracked hashes still match current contents, prompt artifacts for newer sessions are recorded under `provenance/prompts/`, shared index files are not tracked in per-artifact or per-session manifests, session `generated_files` only include artifact-specific outputs, and corpus-derived sessions consistently declare the corpus source class.

## Policy

Read `docs/clean-room-policy.md` before adding or modifying any `SH-*` artifact.
