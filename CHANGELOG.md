# Changelog

## Unreleased

This entry documents the committed duplicate-mapping cleanup only. Duplicate rules
that were created locally but never committed are intentionally omitted.

### Mapping canonicalization

- Canonicalized the compatibility ledger to one internal rule per ShellCheck code.
- Reduced `mappings/shellcheck.yaml` to 332 unique `SC#### -> SH-*` mappings.
- Reduced `discovery/known-codes.yaml` to 332 unique covered ShellCheck codes.
- Kept the oldest committed rule as canonical in each committed duplicate group.

Committed canonical mappings retained:

- `SC1001 -> SH-082`
- `SC1007 -> SH-084`
- `SC1010 -> SH-091`
- `SC2086 -> SH-001`

### Removed committed duplicate artifacts

Removed committed duplicate rule bundles and their associated tracked files:

- `SH-088`, `examples/088.sh`, `provenance/artifacts/SH-088.yaml`
- `SH-090`, `examples/090.sh`, `provenance/artifacts/SH-090.yaml`
- `SH-092`, `examples/092.sh`, `provenance/artifacts/SH-092.yaml`
- `SH-094`, `examples/094.sh`, `provenance/artifacts/SH-094.yaml`
- `SH-095`, `examples/095.sh`, `provenance/artifacts/SH-095.yaml`
- `SH-096`, `examples/096.sh`, `provenance/artifacts/SH-096.yaml`
- `SH-393`, `examples/393.sh`
- `SH-394`, `examples/394.sh`

### Provenance updates

- Trimmed `provenance/ai-sessions/session-018.yaml` to the surviving `SH-091`
  generated files and recomputed its digests.
- Removed `provenance/ai-sessions/session-019.yaml` after retiring its only
  generated artifact, `SH-092`.
- Trimmed `provenance/ai-sessions/session-020.yaml` to the surviving `SH-093`
  generated files and recomputed its digests.

### Verification status

- `./check_dups.sh` passes after the canonicalization.
- `./scripts/verify-oracle.sh` passes after the canonicalization.
- `./scripts/verify-provenance.sh` still reports unrelated pre-existing
  hash/session inconsistencies outside this duplicate cleanup.
