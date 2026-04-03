#!/usr/bin/env python3
"""Create shellcheck reproducers for enriched SC codes.

For each enriched code, asks Claude to write a minimal shell script that
triggers the SC code, then verifies it with shellcheck. On success, creates
the example file, mapping entry, and rule file.

Usage:
    python3 scripts/create-reproducer.py [--limit N] [--codes 1004,1008] [--dry-run] [--retries N]
"""
import argparse
import json
import subprocess
import sys
import textwrap
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
KNOWN_CODES_PATH = ROOT / "discovery" / "known-codes.yaml"
MAPPINGS_PATH = ROOT / "mappings" / "shellcheck.yaml"
EXAMPLES_DIR = ROOT / "examples"
RULES_DIR = ROOT / "rules"

SHELLCHECK_VERSION = "0.11.0"
MAX_RETRIES = 3

# ---------------------------------------------------------------------------
# YAML helpers
# ---------------------------------------------------------------------------

class Dumper(yaml.SafeDumper):
    pass

def _str_representer(dumper, data):
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)

Dumper.add_representer(str, _str_representer)


def load_known_codes() -> tuple[dict, list[dict]]:
    with open(KNOWN_CODES_PATH) as f:
        data = yaml.safe_load(f)
    return data, data.get("known_codes", [])


def save_known_codes(data: dict):
    with open(KNOWN_CODES_PATH, "w") as f:
        yaml.dump(data, f, Dumper=Dumper, default_flow_style=False,
                  sort_keys=False, allow_unicode=True, width=100)


def load_mappings() -> dict:
    with open(MAPPINGS_PATH) as f:
        return yaml.safe_load(f)


def save_mappings(data: dict):
    with open(MAPPINGS_PATH, "w") as f:
        yaml.dump(data, f, Dumper=Dumper, default_flow_style=False,
                  sort_keys=False, allow_unicode=True, width=100)


# ---------------------------------------------------------------------------
# ID allocation
# ---------------------------------------------------------------------------

def next_sh_id(mappings: list[dict]) -> int:
    existing = {int(m["sh_id"].split("-")[1]) for m in mappings}
    n = 1
    while n in existing:
        n += 1
    return n


# ---------------------------------------------------------------------------
# shellcheck verification
# ---------------------------------------------------------------------------

def verify_with_shellcheck(script: str, expected_code: int, shells: list[str]) -> tuple[bool, str, list[int]]:
    """Run shellcheck on a script and check if any shell produces the expected code.

    Returns (success, matching_shell, actual_codes_from_last_attempt).
    """
    import tempfile
    with tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False) as f:
        f.write(script)
        f.flush()
        tmp = Path(f.name)

    last_codes = []
    try:
        for shell in shells:
            result = subprocess.run(
                ["shellcheck", "--norc", "-s", shell, "-S", "style", "-f", "json1", str(tmp)],
                capture_output=True, text=True, timeout=15,
            )
            if result.returncode not in (0, 1):
                continue

            payload = json.loads(result.stdout)
            codes = sorted({c["code"] for c in payload.get("comments", [])})
            last_codes = codes
            if expected_code in codes:
                return True, shell, codes
        return False, "", last_codes
    finally:
        tmp.unlink()


# ---------------------------------------------------------------------------
# Claude reproducer generation
# ---------------------------------------------------------------------------

REPRODUCER_PROMPT = textwrap.dedent("""\
    Write a minimal shell script (under 5 lines) that triggers ShellCheck warning SC{code}.
    SC{code}: {description}
    Applicable shells: {shells}

    Rules:
    - Start with #!/bin/sh or #!/bin/bash (pick whichever is more likely to trigger SC{code})
    - The script must be as short as possible
    - It will be checked with: shellcheck --norc -S style -s <shell> script.sh
    - Do NOT add shellcheck disable directives
    - Output ONLY the script, no explanation, no markdown fences

    {context}
""")

RETRY_PROMPT = textwrap.dedent("""\
    The previous script did not trigger SC{code}. shellcheck produced codes: {actual_codes}
    I need SC{code}: {description}
    Shells tried: {shells}

    Write a DIFFERENT minimal shell script that triggers SC{code}.
    - Start with #!/bin/sh or #!/bin/bash
    - Under 5 lines, no disable directives, no markdown fences
    - Output ONLY the script

    {context}
""")


def qmd_search(code: int) -> str:
    """Get issue context for a code via qmd."""
    result = subprocess.run(
        ["qmd", "search", f"SC{code}"],
        capture_output=True, text=True, timeout=30,
    )
    return result.stdout[:3000] if result.stdout else ""


def ask_claude_for_reproducer(code: int, description: str, shells: list[str],
                              context: str = "",
                              prev_codes: list[int] | None = None,
                              model: str = "haiku") -> str | None:
    shells_str = ", ".join(shells)

    if prev_codes is not None:
        prompt = RETRY_PROMPT.format(
            code=code, description=description, shells=shells_str,
            actual_codes=prev_codes or "none", context=context,
        )
    else:
        prompt = REPRODUCER_PROMPT.format(
            code=code, description=description, shells=shells_str, context=context,
        )

    result = subprocess.run(
        ["claude", "-p", "--model", model, prompt],
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
    return text.strip()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=0,
                        help="Max codes to process (0 = all)")
    parser.add_argument("--codes", type=str, default="",
                        help="Comma-separated SC codes to process")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be done without writing files")
    parser.add_argument("--retries", type=int, default=MAX_RETRIES,
                        help=f"Max retries per code (default: {MAX_RETRIES})")
    parser.add_argument("--model", type=str, default="haiku",
                        help="Claude model to use (default: haiku)")
    args = parser.parse_args()

    data, entries = load_known_codes()
    code_filter = set()
    if args.codes:
        code_filter = {int(c) for c in args.codes.split(",")}

    # Find enriched entries without mappings yet
    mappings_data = load_mappings()
    mappings = mappings_data.get("mappings", [])
    mapped_sc_codes = {m["shellcheck_code"] for m in mappings}

    candidates = []
    for entry in entries:
        if entry.get("status") != "enriched":
            continue
        code = entry["shellcheck_code"]
        if code in mapped_sc_codes:
            continue
        if code_filter and code not in code_filter:
            continue
        candidates.append(entry)

    if args.limit > 0:
        candidates = candidates[:args.limit]

    print(f"Found {len(candidates)} enriched codes to create reproducers for")
    if not candidates:
        return

    created = 0
    for i, entry in enumerate(candidates, 1):
        code = entry["shellcheck_code"]
        description = entry.get("description", "")
        shells = entry.get("shells", ["sh"])

        print(f"[{i}/{len(candidates)}] SC{code}...", end=" ", flush=True)

        if not description:
            print("no description, skipping")
            continue

        if args.dry_run:
            print(f"would generate reproducer")
            continue

        # Get issue context for better prompts
        context = qmd_search(code)

        # Ask Claude, verify across all shells, retry if needed
        script = None
        matched_shell = None
        prev_codes = None
        for attempt in range(1, args.retries + 1):
            candidate_script = ask_claude_for_reproducer(
                code, description, shells, context, prev_codes, args.model,
            )
            if not candidate_script:
                print(f"attempt {attempt}: Claude returned nothing")
                continue

            ok, matched_shell, actual_codes = verify_with_shellcheck(
                candidate_script, code, shells,
            )
            if ok:
                script = candidate_script
                break
            else:
                prev_codes = actual_codes
                if attempt < args.retries:
                    print(f"attempt {attempt}: got {actual_codes}, retrying...", end=" ", flush=True)

        if not script:
            print(f"failed after {args.retries} attempts (last codes: {prev_codes})")
            continue

        # Allocate SH-ID and write files
        sh_num = next_sh_id(mappings)
        sh_id = f"SH-{sh_num:03d}"
        example_name = f"{sh_num:03d}.sh"
        example_path = EXAMPLES_DIR / example_name

        # Write example
        example_path.write_text(script + "\n")

        # Add mapping
        mapping_entry = {
            "sh_id": sh_id,
            "example": f"examples/{example_name}",
            "shellcheck_code": code,
            "shellcheck_version": SHELLCHECK_VERSION,
            "shells": shells,
        }
        mappings.append(mapping_entry)

        # Write rule file
        # Generate a slug from the description
        slug = description.lower()
        for ch in ".,;:!?\"'()[]{}":
            slug = slug.replace(ch, "")
        slug = "-".join(slug.split()[:4])

        rule = {
            "id": sh_id,
            "name": slug,
            "summary": description,
            "shells": shells,
            "example": f"examples/{example_name}",
            "rationale": entry.get("rationale", ""),
        }
        rule_path = RULES_DIR / f"{sh_id}.yaml"
        with open(rule_path, "w") as f:
            yaml.dump(rule, f, Dumper=Dumper, default_flow_style=False,
                      sort_keys=False, allow_unicode=True, width=100)

        # Update known-codes entry
        entry["status"] = "covered"
        entry["sources"] = [f"mappings/{sh_id}"]

        created += 1
        print(f"-> {sh_id} ({example_name})")

    if created > 0 and not args.dry_run:
        mappings_data["mappings"] = mappings
        save_mappings(mappings_data)
        save_known_codes(data)
        print(f"\nCreated {created} reproducers")
    elif args.dry_run:
        print(f"\nDry run — {len(candidates)} codes would be processed")
    else:
        print("\nNo reproducers created")


if __name__ == "__main__":
    main()
