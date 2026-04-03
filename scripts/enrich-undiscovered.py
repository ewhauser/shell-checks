#!/usr/bin/env python3
"""Enrich undiscovered SC codes in known-codes.yaml using qmd + Claude.

For each undiscovered code, searches local issues via `qmd search`, feeds
the results to Claude to determine what the code does, then updates the
known-codes.yaml entry with a description and shell list.

Usage:
    python3 scripts/enrich-undiscovered.py [--limit N] [--codes 1004,1008] [--dry-run]
"""
import argparse
import json
import subprocess
import sys
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KNOWN_CODES_PATH = ROOT / "discovery" / "known-codes.yaml"

# ---------------------------------------------------------------------------
# YAML helpers (minimal, no pyyaml dependency for reading)
# ---------------------------------------------------------------------------

def parse_known_codes(path: Path) -> list[dict]:
    """Parse known-codes.yaml into a list of entry dicts (preserving order)."""
    import yaml
    with open(path) as f:
        data = yaml.safe_load(f)
    return data.get("known_codes", [])


def write_known_codes(path: Path, entries: list[dict], version: str = "0.11.0"):
    """Write entries back to known-codes.yaml."""
    import yaml

    class Dumper(yaml.SafeDumper):
        pass

    # Force block style for lists
    def str_representer(dumper, data):
        if "\n" in data:
            return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
        return dumper.represent_scalar("tag:yaml.org,2002:str", data)

    Dumper.add_representer(str, str_representer)

    doc = {"shellcheck_version": version, "known_codes": entries}
    with open(path, "w") as f:
        yaml.dump(doc, f, Dumper=Dumper, default_flow_style=False, sort_keys=False,
                  allow_unicode=True, width=100)


# ---------------------------------------------------------------------------
# qmd search
# ---------------------------------------------------------------------------

def qmd_search(code: int) -> str:
    """Run `qmd search "SC<code>"` and return the raw output."""
    result = subprocess.run(
        ["qmd", "search", f"SC{code}"],
        capture_output=True, text=True, timeout=30,
    )
    return result.stdout


# ---------------------------------------------------------------------------
# Claude enrichment
# ---------------------------------------------------------------------------

PROMPT_TEMPLATE = textwrap.dedent("""\
    Analyze ShellCheck rule SC{code} from these issue excerpts. Reply with ONLY a JSON object, no markdown.
    Fields: "description" (one sentence, what it checks), "shells" (list from bash/dash/ksh/sh), "rationale" (one sentence, why it matters).
    SC1xxx=parse errors, SC2xxx=warnings(all shells), SC3xxx=portability(sh).

    {excerpts}
""")


def enrich_with_claude(code: int, excerpts: str) -> dict | None:
    """Call Claude via CLI to analyze the SC code and return structured info."""
    prompt = PROMPT_TEMPLATE.format(code=code, excerpts=excerpts[:8000])

    result = subprocess.run(
        ["claude", "-p", "--model", "haiku", prompt],
        capture_output=True, text=True, timeout=120,
    )

    if result.returncode != 0:
        print(f"  Claude error: {result.stderr.strip()}", file=sys.stderr)
        return None

    text = result.stdout.strip()

    # Strip markdown fences if present
    if text.startswith("```"):
        text = "\n".join(text.split("\n")[1:])
    if text.endswith("```"):
        text = "\n".join(text.split("\n")[:-1])
    text = text.strip()

    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # Try to extract JSON from the response
        start = text.find("{")
        end = text.rfind("}") + 1
        if start >= 0 and end > start:
            try:
                return json.loads(text[start:end])
            except json.JSONDecodeError:
                pass
        print(f"  Failed to parse Claude response: {text[:200]}", file=sys.stderr)
        return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=0,
                        help="Max codes to process (0 = all)")
    parser.add_argument("--codes", type=str, default="",
                        help="Comma-separated list of SC codes to process")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be done without calling Claude")
    args = parser.parse_args()

    entries = parse_known_codes(KNOWN_CODES_PATH)
    code_filter = set()
    if args.codes:
        code_filter = {int(c) for c in args.codes.split(",")}

    # Find undiscovered entries
    undiscovered = []
    for entry in entries:
        if entry.get("status") != "undiscovered":
            continue
        code = entry["shellcheck_code"]
        if code_filter and code not in code_filter:
            continue
        undiscovered.append(entry)

    if args.limit > 0:
        undiscovered = undiscovered[:args.limit]

    print(f"Found {len(undiscovered)} undiscovered codes to enrich")

    if not undiscovered:
        return

    updated = 0
    for i, entry in enumerate(undiscovered, 1):
        code = entry["shellcheck_code"]
        print(f"[{i}/{len(undiscovered)}] SC{code}...", end=" ", flush=True)

        # Search for issues referencing this code
        excerpts = qmd_search(code)
        if not excerpts.strip():
            print("no qmd results, skipping")
            continue

        if args.dry_run:
            print(f"found qmd results ({len(excerpts)} chars)")
            continue

        # Ask Claude to analyze
        info = enrich_with_claude(code, excerpts)
        if not info:
            print("Claude returned no usable response")
            continue

        # Update the entry in place
        entry["status"] = "enriched"
        entry["description"] = info.get("description", "")
        entry["shells"] = info.get("shells", entry.get("shells", ["sh"]))
        entry["rationale"] = info.get("rationale", "")
        updated += 1
        print(f"enriched: {info.get('description', '')[:60]}")

    if updated > 0 and not args.dry_run:
        write_known_codes(KNOWN_CODES_PATH, entries)
        print(f"\nUpdated {updated} entries in {KNOWN_CODES_PATH}")
    elif args.dry_run:
        print(f"\nDry run complete — {len(undiscovered)} codes would be processed")
    else:
        print("\nNo entries updated")


if __name__ == "__main__":
    main()
