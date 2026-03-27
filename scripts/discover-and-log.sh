#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
template_path="$root_dir/discovery/discover-and-log-template.md"
known_codes_path="$root_dir/discovery/known-codes.yaml"

# Default model; override with -m flag
model="${CODEX_MODEL:-o3}"

usage() {
  echo "Usage: $0 [-m model]"
  echo "  -m MODEL  Model for codex to use (default: ${model})"
  exit 1
}

while getopts "m:h" opt; do
  case "$opt" in
    m) model="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

next_session=$(ruby -e '
  nums = Dir[File.join(ARGV[0], "provenance", "ai-sessions", "session-*.yaml")].map { |f|
    File.basename(f, ".yaml").sub("session-", "").to_i
  }.sort
  puts (nums.last || 0) + 1
' "$root_dir")
next_session_id="session-$(printf '%03d' "$next_session")"
prompt_artifact_rel="provenance/prompts/$next_session_id/main.txt"

# Render the prompt with all placeholders filled in.
rendered=$(ruby -ryaml -e '
  root = ARGV[0]
  template = File.read(ARGV[1])
  known_codes_path = ARGV[2]
  model = ARGV[3]
  today = ARGV[4]
  next_session_id = ARGV[5]
  prompt_file_path = ARGV[6]

  data = YAML.load_file(known_codes_path)
  version = data.fetch("shellcheck_version").to_s

  # Determine next RB number from existing rules
  rule_nums = Dir[File.join(root, "rules", "SH-*.yaml")].map { |f|
    File.basename(f, ".yaml").sub("SH-", "").to_i
  }.sort
  next_rb = (rule_nums.last || 0) + 1
  next_rb_padded = format("%03d", next_rb)
  next_rb_plus1_padded = format("%03d", next_rb + 1)

  result = template
    .gsub("{{NEXT_RB_NUM}}", next_rb_padded)
    .gsub("{{NEXT_RB_NUM_PLUS_1}}", next_rb_plus1_padded)
    .gsub("{{NEXT_EXAMPLE_NUM}}", next_rb_padded)
    .gsub("{{NEXT_SESSION_ID}}", next_session_id)
    .gsub("{{PROMPT_FILE_PATH}}", prompt_file_path)
    .gsub("{{SHELLCHECK_VERSION}}", version)
    .gsub("{{TODAY}}", today)
    .gsub("{{MODEL}}", model)

  print result
' "$root_dir" "$template_path" "$known_codes_path" "$model" "$(date +%Y-%m-%d)" "$next_session_id" "$prompt_artifact_rel")

mkdir -p "$root_dir/$(dirname "$prompt_artifact_rel")"
printf '%s\n' "$rendered" > "$root_dir/$prompt_artifact_rel"

echo "==> Rendered prompt ($(echo "$rendered" | wc -l | tr -d ' ') lines)"
echo "==> Running codex exec with model: $model"
echo ""

# Run codex in non-interactive mode with workspace write access
codex exec \
  -m "$model" \
  --full-auto \
  -C "$root_dir" \
  - < "$root_dir/$prompt_artifact_rel"

exit_code=0

echo ""
echo "==> Codex finished. Running verification..."
echo ""

ruby "$root_dir/scripts/reconcile-provenance-hashes.rb" "$root_dir"

# Run oracle verification
if "$root_dir/scripts/verify-oracle.sh" --strict; then
  echo "  oracle verification passed"
else
  echo "  oracle verification FAILED" >&2
  exit_code=1
fi

# Run provenance verification
if "$root_dir/scripts/verify-provenance.sh"; then
  echo "  provenance verification passed"
else
  echo "  provenance verification FAILED" >&2
  exit_code=1
fi

if [ "$exit_code" -eq 0 ]; then
  echo ""
  echo "==> All verifications passed."
else
  echo ""
  echo "==> Some verifications failed. Review errors above." >&2
fi

exit "$exit_code"
