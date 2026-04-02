#!/bin/sh
# Extract discovery hints from GitHub issues for undiscovered SC codes.
# Outputs a YAML file mapping each undiscovered code to issue-derived context:
#   - issue numbers that reference it
#   - shell snippets found in those issues
#   - short semantic hints (surrounding text near the code mention)
#
# Usage: ./scripts/extract-issue-hints.sh [--codes CODE1,CODE2,...]
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
issues_dir="$root_dir/issues"
known_file="$root_dir/discovery/known-codes.yaml"
output_file="$root_dir/discovery/issue-hints.yaml"

if [ ! -d "$issues_dir" ]; then
  echo "ERROR: issues/ directory not found" >&2
  exit 1
fi

# Parse optional --codes filter
code_filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --codes) code_filter="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Collect known codes from known-codes.yaml
known_codes=$(grep 'shellcheck_code:' "$known_file" | sed 's/.*shellcheck_code: *//' | sort -n)

# Collect all SC codes referenced in issues (4-digit only).
# Filter out template placeholder "e.g. SC1000" and "Rule Id (if any, e.g. SC1000):"
all_issue_codes=$(grep -ohE 'SC[0-9]{4}' "$issues_dir"/*.md 2>/dev/null \
  | sed 's/SC//' | sort -un)

# SC1000 is the template placeholder in issue forms — only keep it if
# it appears in a non-template context in at least one issue.
real_1000=$(grep -rL 'e\.g\. SC1000' "$issues_dir"/*.md 2>/dev/null \
  | xargs grep -l 'SC1000' 2>/dev/null | wc -l | tr -d ' ')
if [ "$real_1000" -eq 0 ]; then
  all_issue_codes=$(echo "$all_issue_codes" | grep -v '^1000$')
fi

# Find undiscovered codes (in issues but not in known)
undiscovered=""
for code in $all_issue_codes; do
  if ! echo "$known_codes" | grep -qx "$code"; then
    if [ -n "$code_filter" ]; then
      if echo ",$code_filter," | grep -q ",$code,"; then
        undiscovered="$undiscovered $code"
      fi
    else
      undiscovered="$undiscovered $code"
    fi
  fi
done

# Start YAML output
cat > "$output_file" <<EOF
---
generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
source: issues/
description: >
  Discovery hints extracted from ShellCheck GitHub issues for codes
  not yet in known-codes.yaml. Shell snippets are community-authored
  (not ShellCheck source) and can inform independent example authoring.
codes:
EOF

count=0
for code in $undiscovered; do
  # Find issue files that mention this code (not in the template placeholder)
  issue_files=$(grep -lE "SC${code}[^0-9]" "$issues_dir"/*.md 2>/dev/null \
    | grep -v "e\.g\. SC${code}" || true)

  if [ -z "$issue_files" ]; then
    # Double check: some might only appear at end of line
    issue_files=$(grep -lE "SC${code}$" "$issues_dir"/*.md 2>/dev/null || true)
  fi

  [ -z "$issue_files" ] && continue

  # Extract issue numbers
  issue_nums=""
  for f in $issue_files; do
    num=$(basename "$f" .md)
    issue_nums="$issue_nums $num"
  done

  cat >> "$output_file" <<EOF
- code: $code
  issue_count: $(echo "$issue_nums" | wc -w | tr -d ' ')
  issues: [$(echo "$issue_nums" | sed 's/^ //;s/ /, /g')]
EOF

  # Extract shell snippets from the first 3 issues (fenced code blocks)
  snippet_count=0
  has_snippets=false
  for f in $(echo "$issue_files" | head -3); do
    # Get lines around the SC code mention and any fenced code blocks
    snippets=$(awk '
      /^```(sh|bash|shell)?$/ { in_block=1; block=""; next }
      /^```$/ && in_block { in_block=0; if (length(block) > 0 && length(block) < 500) print block; next }
      in_block { block = (block ? block "\n" : "") $0 }
    ' "$f")

    if [ -n "$snippets" ]; then
      if [ "$has_snippets" = false ]; then
        echo "  snippets:" >> "$output_file"
        has_snippets=true
      fi
      # Take first snippet from this issue
      first_snippet=$(echo "$snippets" | head -20)
      issue_num=$(basename "$f" .md)
      printf '  - issue: %s\n' "$issue_num" >> "$output_file"
      printf '    code: |\n' >> "$output_file"
      echo "$first_snippet" | sed 's/^/      /' >> "$output_file"
      snippet_count=$((snippet_count + 1))
      [ "$snippet_count" -ge 3 ] && break
    fi
  done

  # Extract a semantic hint: the line containing the SC code (first meaningful one)
  hint=$(grep -hE "SC${code}" $issue_files 2>/dev/null \
    | grep -v "e\.g\." \
    | grep -v "^- Rule Id" \
    | grep -vi "disable" \
    | grep -vi "exclude" \
    | head -1 \
    | sed 's/^[[:space:]]*//' \
    | cut -c1-200)

  if [ -n "$hint" ]; then
    # Escape for YAML double-quoted string: backslash and double-quote
    hint=$(printf '%s' "$hint" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '  hint: "%s"\n' "$hint" >> "$output_file"
  fi

  count=$((count + 1))
done

# Add summary at top
sed -i.bak "s/^codes:/total_undiscovered: $count\ncodes:/" "$output_file"
rm -f "${output_file}.bak"

echo "Extracted hints for $count undiscovered codes -> $output_file"
