#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

errors=0

# 1. Duplicate rule IDs across rule files
echo "=== Checking for duplicate rule IDs in rules/ ==="
dupes=$(grep -h '^id:' rules/*.yaml | sort | uniq -d)
if [ -n "$dupes" ]; then
  echo "FAIL: Duplicate rule IDs found:"
  echo "$dupes"
  errors=$((errors + 1))
else
  echo "OK: No duplicate rule IDs"
fi

# 2. Duplicate sh_id in mappings
echo ""
echo "=== Checking for duplicate sh_id in mappings ==="
dupes=$(grep '^- sh_id:' mappings/shellcheck.yaml | awk '{print $3}' | sort | uniq -d)
if [ -n "$dupes" ]; then
  echo "FAIL: Duplicate sh_id entries in mappings:"
  echo "$dupes"
  errors=$((errors + 1))
else
  echo "OK: No duplicate sh_id in mappings"
fi

# 3. One-to-one: each shellcheck_code should map to exactly one sh_id
echo ""
echo "=== Checking for 1:1 shellcheck_code to sh_id mapping ==="
dupes=$(paste -d'|' \
  <(grep '^- sh_id:' mappings/shellcheck.yaml | awk '{print $3}') \
  <(grep '  shellcheck_code:' mappings/shellcheck.yaml | awk '{print $2}') \
  | sort -t'|' -k2 -n | awk -F'|' '
  {
    if (code[$2]) code[$2] = code[$2] ", " $1
    else code[$2] = $1
    count[$2]++
  }
  END {
    for (c in count)
      if (count[c] > 1)
        printf "SC%s: %s\n", c, code[c]
  }' | sort)
if [ -n "$dupes" ]; then
  n=$(echo "$dupes" | wc -l | tr -d ' ')
  echo "FAIL: $n shellcheck code(s) map to multiple sh_ids:"
  echo "$dupes"
  errors=$((errors + 1))
else
  echo "OK: Each shellcheck code maps to exactly one sh_id"
fi

# 4. Filename vs id mismatch in rules
echo ""
echo "=== Checking filename/id consistency ==="
mismatch=0
for f in rules/SH-*.yaml; do
  file_id=$(basename "$f" .yaml)
  yaml_id=$(grep '^id:' "$f" | awk '{print $2}')
  if [ "$file_id" != "$yaml_id" ]; then
    echo "MISMATCH: file=$file_id id=$yaml_id"
    mismatch=1
  fi
done
if [ "$mismatch" -eq 1 ]; then
  errors=$((errors + 1))
else
  echo "OK: All filenames match their id field"
fi

# 5. Mapping sh_ids that have no rule file
echo ""
echo "=== Checking for orphaned mapping entries (no rule file) ==="
orphan=0
for id in $(grep '^- sh_id:' mappings/shellcheck.yaml | awk '{print $3}'); do
  if [ ! -f "rules/${id}.yaml" ]; then
    echo "ORPHAN: mapping references $id but rules/${id}.yaml does not exist"
    orphan=1
  fi
done
if [ "$orphan" -eq 1 ]; then
  errors=$((errors + 1))
else
  echo "OK: All mapping sh_ids have corresponding rule files"
fi

# 6. Rule files with no mapping entry
echo ""
echo "=== Checking for unmapped rules (rule file but no mapping) ==="
mapped_ids=$(grep '^- sh_id:' mappings/shellcheck.yaml | awk '{print $3}' | sort)
unmapped=0
for f in rules/SH-*.yaml; do
  file_id=$(basename "$f" .yaml)
  if ! echo "$mapped_ids" | grep -qx "$file_id"; then
    echo "UNMAPPED: $file_id has no entry in mappings/shellcheck.yaml"
    unmapped=1
  fi
done
if [ "$unmapped" -eq 1 ]; then
  errors=$((errors + 1))
else
  echo "OK: All rule files have mapping entries"
fi

echo ""
if [ "$errors" -gt 0 ]; then
  echo "FAILED: $errors check(s) had issues"
  exit 1
else
  echo "ALL CHECKS PASSED"
fi
