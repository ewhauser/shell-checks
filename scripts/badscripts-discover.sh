#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
template_path="$root_dir/discovery/badscripts-template.md"
known_codes_path="$root_dir/discovery/known-codes.yaml"
badscripts_schema="$root_dir/scripts/badscripts-schema.json"
artifact_schema="$root_dir/scripts/artifact-batch-schema.json"

model="${CODEX_MODEL:-gpt-5.4-mini}"
batch_size=10
scripts_per_category=5
parallel_jobs=4
max_codes=0
max_retries=2
reasoning_effort="medium"

usage() {
  echo "Usage: $0 [-m model] [-b batch_size] [-c scripts_per_category] [-j jobs] [-n max_codes] [-r retries] [-e effort]"
  echo "  -m MODEL       Model for codex (default: $model)"
  echo "  -b BATCH_SIZE  Codes per artifact-creation batch (default: $batch_size)"
  echo "  -c COUNT       Scripts per category (default: $scripts_per_category)"
  echo "  -j JOBS        Parallel shellcheck jobs (default: $parallel_jobs)"
  echo "  -n MAX_CODES   Maximum new codes to process (default: all)"
  echo "  -r RETRIES     Max retries per batch for failed artifacts (default: $max_retries)"
  echo "  -e EFFORT      Reasoning effort: low, medium, high, xhigh (default: $reasoning_effort)"
  exit 1
}

while getopts "m:b:c:j:n:r:e:h" opt; do
  case "$opt" in
    m) model="$OPTARG" ;;
    b) batch_size="$OPTARG" ;;
    c) scripts_per_category="$OPTARG" ;;
    j) parallel_jobs="$OPTARG" ;;
    n) max_codes="$OPTARG" ;;
    r) max_retries="$OPTARG" ;;
    e) reasoning_effort="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

today=$(date +%Y-%m-%d)
sc_version=$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("shellcheck_version")' "$known_codes_path")

# -------------------------------------------------------------------
# Phase 1: Generate bad shell scripts
# -------------------------------------------------------------------

echo "==> Phase 1: Generating bad shell scripts ($scripts_per_category per category)..."

# Render template
prompt_file="$tmpdir/generation_prompt.txt"
ruby -ryaml -e '
  template = File.read(ARGV[0])
  scripts_per_category = ARGV[1]

  result = template
    .gsub("{{SCRIPTS_PER_CATEGORY}}", scripts_per_category)

  print result
' "$template_path" "$scripts_per_category" > "$prompt_file"

llm_output="$tmpdir/generation_output.json"

codex exec \
  -m "$model" \
  -c "model_reasoning_effort=\"${reasoning_effort}\"" \
  -c web_search='"disabled"' \
  --output-schema "$badscripts_schema" \
  -s read-only \
  -C "$root_dir" \
  -o "$llm_output" \
  - < "$prompt_file" 2>&1 | sed 's/^/    [codex] /' || true

if [ ! -s "$llm_output" ]; then
  echo "    ERROR: codex produced no output" >&2
  exit 1
fi

# Write generated scripts to tmpdir
scripts_dir="$tmpdir/scripts"
mkdir -p "$scripts_dir"

num_scripts=$(ruby -rjson -e '
  data = JSON.parse(File.read(ARGV[0]))
  scripts = data.is_a?(Hash) ? data.fetch("scripts") : data
  scripts_dir = ARGV[1]
  scripts.each_with_index do |item, idx|
    filename = item.fetch("filename")
    shells = Array(item.fetch("shells"))
    shell = shells.first
    content = item.fetch("script").gsub("\\n", "\n")
    content += "\n" unless content.end_with?("\n")
    path = File.join(scripts_dir, "#{idx}_#{shell}_#{filename}")
    File.write(path, content)
    File.chmod(0755, path)
  end
  puts scripts.length
' "$llm_output" "$scripts_dir")

echo "    Generated $num_scripts scripts"

# -------------------------------------------------------------------
# Phase 2: Scan generated scripts with shellcheck
# -------------------------------------------------------------------

echo "==> Phase 2: Scanning generated scripts with shellcheck..."

scan_helper=$(mktemp)
cat > "$scan_helper" <<'HELPER'
#!/bin/sh
set -eu
file="$1"
# Extract shell from filename: idx_SHELL_rest
basename_f=$(basename "$file")
shell=$(echo "$basename_f" | cut -d'_' -f2)
case "$shell" in
  sh|bash) ;; *) shell="sh" ;;
esac

set +e
sc_out=$(shellcheck --norc -s "$shell" -f json1 "$file" 2>/dev/null)
sc_exit=$?
set -e

# Exit codes 0 (clean) and >2 (crash) produce no useful output
case "$sc_exit" in
  1|2) ;;
  *) exit 0 ;;
esac

[ -z "$sc_out" ] && exit 0

ruby -rjson -e '
  file = ARGV[0]
  shell = ARGV[1]
  begin
    data = JSON.parse($stdin.read)
    comments = data.fetch("comments", [])
    comments.each do |c|
      code = c.fetch("code")
      line_num = c.fetch("line")
      end_line = c.fetch("endLine")
      end_line = line_num + 4 if end_line > line_num + 4
      source_lines = File.readlines(file)[line_num - 1..end_line - 1]
      next unless source_lines
      escaped = source_lines.join("").gsub("\n", "␤").strip
      puts "#{code}\t#{shell}\t#{line_num}\t#{escaped}"
    end
  rescue
    # Ignore parse errors in shellcheck output
  end
' "$file" "$shell" <<EOF
$sc_out
EOF
HELPER
chmod +x "$scan_helper"

raw_scan_tsv="$tmpdir/raw_scan.tsv"
: > "$raw_scan_tsv"

find "$scripts_dir" -type f -name '*.sh' -print0 | \
  xargs -0 -n 1 -P "$parallel_jobs" "$scan_helper" \
  >> "$raw_scan_tsv" 2>/dev/null || true

total_hits=$(wc -l < "$raw_scan_tsv" | tr -d ' ')
echo "    Found $total_hits total code hits across all scripts"

# Deduplicate: merge hints per code, keep up to 5 hints per code
code_lines_tsv="$tmpdir/code_lines.tsv"
ruby -e '
  hints = {}
  shells = {}
  File.readlines(ARGV[0]).each do |line|
    parts = line.chomp.split("\t", 4)
    next if parts.length < 4
    code, shell, _line, escaped = parts
    hints[code] ||= []
    shells[code] = shell
    hint = escaped.strip
    hints[code] << hint unless hints[code].include?(hint)
  end
  hints.each do |code, hint_list|
    combined = hint_list.first(5).join("⏎")
    puts "#{code}\t#{shells[code]}\t0\t#{combined}"
  end
' "$raw_scan_tsv" > "$code_lines_tsv"

unique_codes=$(wc -l < "$code_lines_tsv" | tr -d ' ')
echo "    Found $unique_codes unique codes"

rm -f "$scan_helper" "$raw_scan_tsv"

# -------------------------------------------------------------------
# Phase 3: Filter against known codes
# -------------------------------------------------------------------

echo "==> Phase 3: Filtering against known codes..."

new_codes_tsv="$tmpdir/new_codes.tsv"
ruby -ryaml -e '
  known_data = YAML.load_file(ARGV[1])
  known_set = Array(known_data["known_codes"]).map { |k| k["shellcheck_code"].to_s }.uniq

  new_lines = []
  File.readlines(ARGV[0]).each do |line|
    code = line.split("\t", 2).first
    new_lines << line unless known_set.include?(code)
  end

  new_lines.each { |l| print l }
' "$code_lines_tsv" "$known_codes_path" > "$new_codes_tsv"

new_count=$(wc -l < "$new_codes_tsv" | tr -d ' ')
known_count=$((unique_codes - new_count))
echo "    $new_count new codes ($known_count already known)"

if [ "$new_count" -eq 0 ]; then
  echo "==> No new codes discovered. Done."
  exit 0
fi

if [ "$max_codes" -gt 0 ] && [ "$new_count" -gt "$max_codes" ]; then
  echo "    Limiting to $max_codes codes"
  head -n "$max_codes" "$new_codes_tsv" > "${new_codes_tsv}.tmp"
  mv "${new_codes_tsv}.tmp" "$new_codes_tsv"
  new_count="$max_codes"
fi

# -------------------------------------------------------------------
# Phase 4: Create artifacts (batched)
# -------------------------------------------------------------------

echo "==> Phase 4: Creating artifacts for $new_count new codes in batches of $batch_size..."

batch_num=0
total_created=0
total_skipped=0
while [ -s "$new_codes_tsv" ]; do
  batch_num=$((batch_num + 1))

  batch_file=$(mktemp)
  head -n "$batch_size" "$new_codes_tsv" > "$batch_file"
  tail -n "+$((batch_size + 1))" "$new_codes_tsv" > "${new_codes_tsv}.tmp"
  mv "${new_codes_tsv}.tmp" "$new_codes_tsv"

  batch_count=$(wc -l < "$batch_file" | tr -d ' ')
  [ "$batch_count" -eq 0 ] && { rm -f "$batch_file"; break; }

  # Determine next RB number
  next_rb=$(ruby -e '
    nums = Dir[File.join(ARGV[0], "rules", "SH-*.yaml")].map { |f|
      File.basename(f, ".yaml").sub("SH-", "").to_i
    }.sort
    puts (nums.last || 0) + 1
  ' "$root_dir")

  next_session=$(ruby -e '
    nums = Dir[File.join(ARGV[0], "provenance", "ai-sessions", "session-*.yaml")].map { |f|
      File.basename(f, ".yaml").sub("session-", "").to_i
    }.sort
    puts (nums.last || 0) + 1
  ' "$root_dir")
  next_session_id="session-$(printf '%03d' "$next_session")"

  echo ""
  echo "==> Batch $batch_num: $batch_count codes (SH-$(printf '%03d' "$next_rb")+, $next_session_id)"

  # Build prompt with ruby to avoid shell expansion issues
  batch_prompt="$tmpdir/prompt_batch_${batch_num}.txt"
  ruby -e '
    next_rb = ARGV[0].to_i
    batch_file = ARGV[1]
    prompt_path = ARGV[2]

    codes_block = []
    File.readlines(batch_file).each_with_index do |line, idx|
      parts = line.chomp.split("\t", 4)
      next if parts.length < 4
      code, shell, _line_num, combined_hints = parts
      sh_padded = "%03d" % (next_rb + idx)
      hints = combined_hints.split("⏎")
      codes_block << "- code: #{code}, sh_id: SH-#{sh_padded}, shell: #{shell}, hints:"
      hints.each_with_index do |hint, hi|
        restored = hint.gsub("␤", "\n")
        codes_block << "  Example #{hi + 1}:"
        codes_block << "  ```"
        codes_block << "  " + restored.gsub("\n", "\n  ")
        codes_block << "  ```"
      end
    end

    prompt = <<~PROMPT
      For each shell code below, write a minimal shell script (1-5 lines) that triggers
      the target shellcheck code, plus a short name and description. Use the hints to
      understand what construct triggers the code, but write your own independent example.

      Codes:
      #{codes_block.join("\n")}

      Rules:
      - example_script MUST start with #!/bin/sh or #!/bin/bash as appropriate
      - Do NOT copy the hint verbatim — write your own minimal triggering example
      - Minimize extra shellcheck codes; companion parser/context diagnostics are acceptable only when tightly coupled to the same construct
      - Do NOT reuse ShellCheck diagnostic wording
      - Compatibility identifiers may appear as bare numbers or SC1234, but do not reuse ShellCheck diagnostic wording
      - If you need to suppress other warnings in example_script, use numeric codes only (e.g. "# shellcheck disable=1072,1073")
      - Keep name, summary, rationale SHORT
      - Do NOT run any commands or write any files
    PROMPT
    File.write(prompt_path, prompt)
  ' "$next_rb" "$batch_file" "$batch_prompt"

  # Get LLM response
  llm_output="$tmpdir/llm_batch_${batch_num}.json"
  llm_clean="$tmpdir/clean_batch_${batch_num}.json"

  codex exec \
    -m "$model" \
    -c "model_reasoning_effort=\"${reasoning_effort}\"" \
    -c web_search='"disabled"' \
    --output-schema "$artifact_schema" \
    -s read-only \
    -C "$root_dir" \
    -o "$llm_output" \
    - < "$batch_prompt" 2>&1 | sed 's/^/    [codex] /' || true

  if [ ! -s "$llm_output" ]; then
    echo "    ERROR: codex produced no output"
  else
    echo "    LLM output: $(wc -c < "$llm_output" | tr -d ' ') bytes"
  fi

  # Extract artifacts array from structured output
  ruby -rjson -e '
    raw = File.read(ARGV[0])
    data = JSON.parse(raw)
    items = data.is_a?(Hash) ? data.fetch("artifacts") : data
    puts JSON.pretty_generate(items)
  ' "$llm_output" > "$llm_clean" 2>&1 || true

  if [ ! -s "$llm_clean" ]; then
    echo "    ERROR: Failed to parse LLM response, skipping batch"
    rm -f "$batch_file"
    continue
  fi

  # Create artifacts, retrying failures up to max_retries times
  current_json="$llm_clean"
  current_prompt_file="$batch_prompt"
  failures_json="$tmpdir/failures_batch_${batch_num}.json"
  attempt=0
  batch_created=0
  batch_skipped=0
  batch_sh_ids=""

  while [ "$attempt" -le "$max_retries" ]; do
    attempt=$((attempt + 1))

    if [ "$attempt" -gt 1 ]; then
      next_session=$(ruby -e '
        nums = Dir[File.join(ARGV[0], "provenance", "ai-sessions", "session-*.yaml")].map { |f|
          File.basename(f, ".yaml").sub("session-", "").to_i
        }.sort
        puts (nums.last || 0) + 1
      ' "$root_dir")
      next_session_id="session-$(printf '%03d' "$next_session")"
    fi

    prompt_sources="$tmpdir/prompt_sources_${batch_num}_${attempt}.txt"
    printf '%s\n' "$current_prompt_file" > "$prompt_sources"

    result=$(ruby "$root_dir/scripts/create-artifacts-from-json.rb" \
      "$root_dir" "$sc_version" "$today" "$next_session_id" "$model" \
      "$current_json" "$failures_json" "synthetic" "$prompt_sources" 2>&1)
    echo "$result"

    step_ok=$(echo "$result" | grep -c "^  OK " || true)
    step_skip=$(echo "$result" | grep -c "^  SKIP " || true)
    batch_created=$((batch_created + step_ok))
    batch_skipped=$step_skip
    new_ids=$(echo "$result" | grep "^  OK " | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
    if [ -n "$new_ids" ]; then
      batch_sh_ids="${batch_sh_ids:+${batch_sh_ids},}${new_ids}"
    fi

    if [ ! -s "$failures_json" ] || [ "$attempt" -gt "$max_retries" ]; then
      break
    fi

    num_failures=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).length' "$failures_json")
    echo "    Retrying $num_failures failed items (attempt $((attempt + 1))/$((max_retries + 1)))..."

    retry_prompt=$(ruby -rjson -e '
      items = JSON.parse(File.read(ARGV[0]))
      puts "Your previous examples triggered wrong shellcheck codes. Fix each one so it triggers"
      puts "ONLY the target code. Here is what went wrong:"
      puts ""
      items.each do |item|
        actual = item["actual_codes"] || []
        shells = Array(item["shells"]).join(", ")
        puts "- #{item["sh_id"]} (target: #{item["code"]}, shells: [#{shells}]): your example triggered #{actual.inspect}"
        puts "  Your script was: #{item["example_script"]}"
        puts "  Write a simpler/different example that triggers ONLY code #{item["code"]}."
        puts ""
      end
      puts "Respond with ONLY a JSON array, same format as before. Each element:"
      puts "{ \"sh_id\", \"code\", \"shell\", \"name\", \"summary\", \"rationale\", \"example_script\" }"
      puts ""
      puts "Rules:"
      puts "- example_script MUST start with #!/bin/sh or #!/bin/bash"
      puts "- Keep examples minimal (1-3 lines) to avoid triggering extra codes"
      puts "- Do NOT run any commands — just return the JSON array"
      puts "- Respond with NOTHING except the JSON array"
    ' "$failures_json")

    retry_output="$tmpdir/retry_${batch_num}_${attempt}.json"
    retry_clean="$tmpdir/retry_clean_${batch_num}_${attempt}.json"
    retry_prompt_file="$tmpdir/retry_prompt_${batch_num}_${attempt}.txt"
    printf '%s\n' "$retry_prompt" > "$retry_prompt_file"

    codex exec \
      -m "$model" \
      -c "model_reasoning_effort=\"${reasoning_effort}\"" \
      -c web_search='"disabled"' \
      --output-schema "$artifact_schema" \
      -s read-only \
      -C "$root_dir" \
      -o "$retry_output" \
      - < "$retry_prompt_file" >/dev/null 2>&1 || true

    ruby -rjson -e '
      raw = File.read(ARGV[0])
      data = JSON.parse(raw)
      items = data.is_a?(Hash) ? data.fetch("artifacts") : data
      puts JSON.pretty_generate(items)
    ' "$retry_output" > "$retry_clean" 2>/dev/null || true

    if [ ! -s "$retry_clean" ]; then
      echo "    Retry failed to parse LLM response, giving up on remaining"
      break
    fi

    current_json="$retry_clean"
    current_prompt_file="$retry_prompt_file"
    rm -f "$failures_json"
  done

  total_created=$((total_created + batch_created))
  total_skipped=$((total_skipped + batch_skipped))

  # Reconcile provenance hashes
  ruby "$root_dir/scripts/reconcile-provenance-hashes.rb" "$root_dir"

  # Verify before moving to next batch
  batch_ok=true
  if [ -n "$batch_sh_ids" ]; then
    oracle_args="--only $batch_sh_ids"
  else
    oracle_args=""
  fi
  if ! "$root_dir/scripts/verify-oracle.sh" --strict $oracle_args >/dev/null 2>&1; then
    echo "    Oracle verification FAILED for batch $batch_num" >&2
    "$root_dir/scripts/verify-oracle.sh" --strict $oracle_args 2>&1 | grep -v "^verified" >&2
    batch_ok=false
  fi
  if ! "$root_dir/scripts/verify-provenance.sh" >/dev/null 2>&1; then
    echo "    Provenance verification FAILED for batch $batch_num" >&2
    "$root_dir/scripts/verify-provenance.sh" 2>&1 | grep -v "^provenance" >&2
    batch_ok=false
  fi

  if [ "$batch_ok" = true ]; then
    echo "    Batch $batch_num verified OK ($batch_created created, $batch_skipped skipped)"
  else
    echo "    Batch $batch_num FAILED verification. Stopping." >&2
    rm -f "$batch_file"
    break
  fi

  rm -f "$batch_file"
done

echo ""
echo "==> Done. $total_created artifacts created, $total_skipped skipped."
