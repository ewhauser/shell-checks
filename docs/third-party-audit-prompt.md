# Third-Party Audit Prompt

Use this prompt with an external reviewer or another model to perform an evidence-based audit of this repository's clean-room implementation.

---

You are acting as an independent third-party auditor reviewing a repository that claims to implement a clean-room process for shell lint compatibility artifacts.

Your job is not to endorse the project at face value. Your job is to test whether the repository's controls, evidence, and verification steps support its stated clean-room claims, and whether a comparison against official ShellCheck materials reveals likely copied assets in newly added rules.

Work only from evidence you can inspect directly in the repository and from local commands you can run in the repository. Do not give legal conclusions. Do not claim absolute proof of independence. State clearly what the evidence supports, what it does not support, and what remains unverified.

Treat the repository's clean-room claim according to the scope stated in its own policy. If the policy limits the clean-room restriction to ShellCheck-origin materials, then the use of unrelated third-party shell scripts or corpus-derived hints is not by itself evidence of ShellCheck copying. Evaluate instead whether that scope is stated clearly, enforced consistently, and reflected accurately in committed authored artifacts.

## Primary Objective

Produce a written audit report assessing whether the repository demonstrates a credible, internally consistent, and verifiable clean-room implementation.

## Scope

Evaluate at minimum:

- policy and governance controls
- artifact completeness for `SH-*` bundles
- provenance record quality and integrity
- separation between discovery and authoring lanes
- restrictions on compatibility identifier usage
- oracle reproducibility using the local verification scripts
- external similarity review against official ShellCheck materials for newly added or recently modified rules
- practical weaknesses, ambiguities, or unverifiable assumptions in the clean-room design

## Evidence You Should Review

Read at least these files and directories:

- `README.md`
- `docs/clean-room-policy.md`
- `scripts/verify-oracle.sh`
- `scripts/verify-provenance.sh`
- `discovery/README.md`
- `discovery/prompt-template.md`
- `mappings/shellcheck.yaml`
- `rules/`
- `examples/`
- `provenance/artifacts/`
- `provenance/ai-sessions/`

For the external comparison lane, also review official ShellCheck materials on the public web. Restrict external review to official sources, prioritized as follows:

- `https://github.com/koalaman/shellcheck/wiki`
- `https://github.com/koalaman/shellcheck`
- any directly linked official ShellCheck wiki pages for the mapped `SC####` codes under review

Do not use gists, blog posts, mirrors, or third-party summaries as primary evidence for copied-material analysis.

## Required Audit Procedures

Perform these steps and use the results in your report:

1. Read the repository policy and summarize the stated clean-room controls in your own words.
2. Inspect the repository structure and determine whether the file layout supports the claimed process separation.
3. Review the verification scripts and explain what they do and do not prove.
4. Run the local verification commands:
   - `./scripts/verify-oracle.sh --strict`
   - `./scripts/verify-provenance.sh`
5. Sample multiple `SH-*` artifacts across the repository, including at least:
   - the seed artifact `SH-001`
   - at least two mid-range artifacts
   - at least two recent artifacts
6. For each sampled artifact, verify that the expected bundle exists:
   - rule spec
   - example script
   - mapping entry
   - artifact provenance record
   - AI session record when referenced
7. Confirm whether the provenance records are internally coherent:
   - file hashes match current files
   - session file lists match artifact file entries
   - shared index files are handled consistently with the documented exception
   - session size limits are respected where applicable
8. Check whether compatibility identifiers are isolated to allowed areas and flag any leakage into authored prose or example comments.
9. Review the discovery lane and assess whether it is meaningfully separated from rule authoring.
10. Identify any places where the repository relies on assertion instead of auditable evidence.
11. Identify the newest or recently modified `SH-*` artifacts. Prefer:
   - uncommitted or modified rule files visible in `git status`
   - otherwise, the highest-numbered `SH-*` artifacts present in `rules/`
12. Use web search and direct page review of official ShellCheck wiki materials for the mapped `SC####` codes corresponding to those recent artifacts.
13. Compare the recent repo-authored assets against the official external materials, checking at minimum:
   - rule names
   - summaries
   - rationales
   - example script structure
   - unusually distinctive wording, ordering, or edge-case framing
14. Classify any overlap you find as one of:
   - exact copying
   - close paraphrase
   - distinctive structural similarity
   - generic semantic overlap only
15. Treat this external comparison as an audit-only procedure. Do not recommend copying, adapting, or importing external ShellCheck wording back into repository-authored files.
16. Distinguish clearly between:
   - controls that are implemented and tested
   - controls that are documented but not strongly enforced
   - claims that cannot be validated from repository evidence alone
   - concerns raised only by external similarity review

## Audit Standards For This Review

Use the following decision standard:

- `Pass`: the control is clearly implemented, evidenced, and consistent with the repository's stated policy.
- `Partial`: the control exists but is incomplete, weakly enforced, ambiguous, or dependent on manual discipline.
- `Fail`: the control is missing, contradicted by evidence, or does not work as described.
- `Not Verifiable`: the claim may be plausible, but the repository does not contain enough evidence to support a confident conclusion.

Treat the audit as a process-and-evidence review, not a plagiarism detector and not a legal certification.

## Specific Questions You Must Answer

Answer these explicitly in the report:

1. Does the repository define a coherent clean-room policy?
2. Do the repository structure and workflows reinforce that policy in practice?
3. Do the verification scripts provide meaningful control coverage, and where are the gaps?
4. Does the provenance model create a credible audit trail for authored artifacts?
5. Is the separation between discovery outputs and clean-room authored artifacts adequately controlled?
6. Are there any signs that prohibited identifiers or copied compatibility material leaked into authored files?
7. Does comparison against official ShellCheck wiki material suggest that any newly added or recently modified rules copied or closely paraphrased external assets?
8. What parts of the clean-room claim remain unprovable from in-repo evidence alone?
9. What are the highest-priority remediation steps to improve third-party confidence?

## Report Requirements

Return a report with exactly these sections:

### 1. Executive Summary

Provide a short overall conclusion using cautious, evidence-based language.

### 2. Scope and Method

List the repository areas reviewed, commands run, and sampling approach used.

### 3. Control Assessment

Use a flat table with these columns:

- Control Area
- Rating
- Evidence
- Auditor Notes

Include at least these control areas:

- Policy definition
- Repository segregation
- Artifact completeness
- Provenance integrity
- Oracle reproducibility
- Identifier hygiene
- Discovery lane separation
- External similarity review
- Enforcement strength

### 4. Findings

List each finding separately. For each finding include:

- severity: `critical`, `high`, `medium`, or `low`
- title
- evidence with file paths and commands where relevant
- why it matters
- recommended remediation

If there are no material findings, say so explicitly and still list residual risks.

### 5. Assurance Limits

Explain what this audit cannot prove from repository evidence alone. Be explicit about missing chain-of-custody, author intent, and the fact that external similarity review can indicate suspicious overlap but cannot exhaustively prove the absence of copying.

### 6. Conclusion

State whether the repository currently presents:

- a credible clean-room implementation
- a partially credible clean-room implementation with notable gaps
- or an insufficiently evidenced clean-room implementation

Justify the conclusion in a short paragraph.

### 7. Appendix

Include:

- commands run
- artifacts sampled
- external wiki pages reviewed
- any failed checks or unavailable tools

## Output Style Constraints

- Be skeptical, precise, and fair.
- Cite concrete file paths for substantive claims.
- Cite exact external URLs for any copied-material concerns.
- Prefer short quotations only when necessary; otherwise summarize in your own words.
- Do not use marketing language.
- Do not make legal conclusions.
- Do not infer compliance beyond the available evidence.
- If verification commands fail, treat that as audit evidence and discuss the impact.
- If external pages are unavailable or incomplete, say so and limit conclusions accordingly.

## Final Instruction

Write the report now. Base every conclusion on repository evidence or command results. If you make an inference, label it clearly as an inference.
