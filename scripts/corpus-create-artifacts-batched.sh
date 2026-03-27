#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
scan_results="$root_dir/corpus/scan-results.yaml"
scripts_dir="$root_dir/corpus/scripts"
known_codes_path="$root_dir/discovery/known-codes.yaml"
mappings_path="$root_dir/mappings/shellcheck.yaml"

model="${CODEX_MODEL:-gpt-5.4-mini}"
reasoning="${CODEX_REASONING:-medium}"
batch_size=10
parallel_jobs=4

usage() {
  echo "Usage: $0 [-m model] [-r reasoning] [-b batch_size] [-j jobs] [-s start_offset] [-n max_codes]"
  echo "  -m MODEL       Model for codex (default: $model)"
  echo "  -r REASONING   Reasoning effort: low|medium|high (default: $reasoning)"
  echo "  -b BATCH_SIZE  Codes per batch (default: $batch_size)"
  echo "  -j JOBS        Parallel shellcheck jobs (default: $parallel_jobs)"
  echo "  -s OFFSET      Skip first N codes (default: 0)"
  echo "  -n MAX_CODES   Maximum total codes to process (default: all)"
  exit 1
}

start_offset=0
max_codes=0
while getopts "m:r:b:j:s:n:h" opt; do
  case "$opt" in
    m) model="$OPTARG" ;;
    r) reasoning="$OPTARG" ;;
    b) batch_size="$OPTARG" ;;
    j) parallel_jobs="$OPTARG" ;;
    s) start_offset="$OPTARG" ;;
    n) max_codes="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [ ! -f "$scan_results" ]; then
  echo "No scan results at $scan_results — run corpus-scan.sh first" >&2
  exit 1
fi

today=$(date +%Y-%m-%d)
sc_version=$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("shellcheck_version")' "$known_codes_path")

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

# -------------------------------------------------------------------
# Phase 1: Extract triggering lines from corpus
# -------------------------------------------------------------------

echo "==> Phase 1: Extracting triggering lines from corpus..."

code_file_tsv=$(mktemp)

# Emit up to 5 example files per code for richer hints
ruby -ryaml -e '
  data = YAML.load_file(ARGV[0])
  known = YAML.load_file(ARGV[1])
  covered = Array(known["known_codes"]).map { |k| k["shellcheck_code"] }.uniq
  new_codes = Array(data.fetch("new_codes", [])) - covered
  details = data.fetch("code_details", {})
  new_codes.each do |code|
    d = details[code]
    next unless d
    files = Array(d["example_files"])
    next if files.empty?
    files.first(5).each { |f| puts "#{code}\t#{f}" }
  end
' "$scan_results" "$known_codes_path" > "$code_file_tsv"

total_pairs=$(wc -l < "$code_file_tsv" | tr -d ' ')
total_codes=$(awk -F'\t' '{print $1}' "$code_file_tsv" | sort -u | wc -l | tr -d ' ')
echo "    $total_codes codes to process ($total_pairs code/file pairs)"

extract_helper=$(mktemp)
cat > "$extract_helper" <<'HELPER'
#!/bin/sh
set -eu
code="$1"
file="$2"
scripts_dir="$3"

filepath="$scripts_dir/$file"
[ ! -f "$filepath" ] && exit 0

shebang=$(head -1 "$filepath" 2>/dev/null || true)
case "$shebang" in
  *bash*) shell="bash" ;; *ksh*) shell="ksh" ;; *zsh*) shell="zsh" ;; *) shell="sh" ;;
esac

line_info=$(timeout 10 shellcheck --norc -s "$shell" -f json1 "$filepath" 2>/dev/null | \
  ruby -rjson -e '
    target = ARGV[0].to_i
    data = JSON.parse($stdin.read)
    hit = data.fetch("comments", []).find { |c| c.fetch("code") == target }
    puts "#{hit.fetch("line")}\t#{hit.fetch("endLine")}" if hit
  ' "$code" 2>/dev/null || true)

[ -z "$line_info" ] && exit 0

line_num=$(echo "$line_info" | cut -f1)
end_line=$(echo "$line_info" | cut -f2)
[ "$end_line" -gt "$((line_num + 4))" ] && end_line=$((line_num + 4))
source_lines=$(sed -n "${line_num},${end_line}p" "$filepath" 2>/dev/null || true)
[ -z "$source_lines" ] && exit 0

escaped_lines=$(printf '%s' "$source_lines" | tr '\n' '␤')
printf '%s\t%s\t%s\t%s\n' "$code" "$shell" "$line_num" "$escaped_lines"
HELPER
chmod +x "$extract_helper"

raw_hints_tsv=$(mktemp)

awk -F'\t' '{printf "%s\n%s\n", $1, $2}' "$code_file_tsv" | \
  xargs -n 2 -P "$parallel_jobs" sh -c \
    '"'"$extract_helper"'" "$1" "$2" "'"$scripts_dir"'"' _ \
  >> "$raw_hints_tsv" 2>/dev/null || true

# Merge multiple hints per code into one line: code\tshell\thint1⏎hint2⏎...
# Uses ⏎ as the hint separator (distinct from ␤ which separates lines within a hint)
code_lines_tsv=$(mktemp)
ruby -e '
  hints = {}
  shells = {}
  File.readlines(ARGV[0], encoding: "UTF-8", invalid: :replace, undef: :replace).each do |line|
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
' "$raw_hints_tsv" > "$code_lines_tsv"

extracted=$(wc -l < "$code_lines_tsv" | tr -d ' ')
echo "    Extracted triggering lines for $extracted codes"
rm -f "$code_file_tsv" "$extract_helper" "$raw_hints_tsv"

# -------------------------------------------------------------------
# Phase 2: For each batch, get LLM JSON then immediately create artifacts
# -------------------------------------------------------------------

echo "==> Phase 2: Processing codes in batches of $batch_size..."

if [ "$start_offset" -gt 0 ]; then
  echo "    Skipping first $start_offset codes"
  tail -n "+$((start_offset + 1))" "$code_lines_tsv" > "${code_lines_tsv}.tmp"
  mv "${code_lines_tsv}.tmp" "$code_lines_tsv"
  remaining=$(wc -l < "$code_lines_tsv" | tr -d ' ')
  echo "    $remaining codes remaining"
fi

if [ "$max_codes" -gt 0 ]; then
  echo "    Limiting to $max_codes codes"
  head -n "$max_codes" "$code_lines_tsv" > "${code_lines_tsv}.tmp"
  mv "${code_lines_tsv}.tmp" "$code_lines_tsv"
fi

batch_num=0
total_created=0
total_skipped=0
while [ -s "$code_lines_tsv" ]; do
  batch_num=$((batch_num + 1))

  batch_file=$(mktemp)
  head -n "$batch_size" "$code_lines_tsv" > "$batch_file"
  tail -n "+$((batch_size + 1))" "$code_lines_tsv" > "${code_lines_tsv}.tmp"
  mv "${code_lines_tsv}.tmp" "$code_lines_tsv"

  batch_count=$(wc -l < "$batch_file" | tr -d ' ')
  [ "$batch_count" -eq 0 ] && { rm -f "$batch_file"; break; }

  # Determine next RB number (recalculate each batch since artifacts are created incrementally)
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

  # Build full prompt with ruby to avoid shell expansion of backslashes and $ in hints
  prompt_file="$tmpdir/prompt_batch_${batch_num}.txt"
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
      codes_block << "- code: #{code}, sh_id: SH-#{sh_padded}, shells: [#{shell}], hints:"
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
      - Set requires_dataflow to true if the rule requires cross-statement analysis (e.g. tracking how values flow through assignments, control-flow reachability, or how a declaration on one line affects interpretation on another)
      - Do NOT run any commands or write any files
    PROMPT
    File.write(prompt_path, prompt)
  ' "$next_rb" "$batch_file" "$prompt_file"

  # Get LLM response
  llm_output="$tmpdir/llm_batch_${batch_num}.json"
  llm_clean="$tmpdir/clean_batch_${batch_num}.json"

  schema_path="$root_dir/scripts/artifact-batch-schema.json"

  codex exec \
    -m "$model" \
    -c model_reasoning_effort="\"$reasoning\"" \
    -c web_search='"disabled"' \
    --output-schema "$schema_path" \
    -s read-only \
    -C "$root_dir" \
    -o "$llm_output" \
    - < "$prompt_file" 2>&1 | sed 's/^/    [codex] /' || true

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
  max_retries=2
  current_json="$llm_clean"
  current_prompt_file="$prompt_file"
  failures_json="$tmpdir/failures_batch_${batch_num}.json"
  attempt=0
  batch_created=0
  batch_skipped=0
  batch_sh_ids=""

  while [ "$attempt" -le "$max_retries" ]; do
    attempt=$((attempt + 1))

    if [ "$attempt" -gt 1 ]; then
      # Recalculate session ID for retry
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
      "$current_json" "$failures_json" "corpus" "$prompt_sources" 2>&1)
    echo "$result"

    # Accumulate counts and collect created SH-IDs
    step_ok=$(echo "$result" | grep -c "^  OK " || true)
    step_skip=$(echo "$result" | grep -c "^  SKIP " || true)
    batch_created=$((batch_created + step_ok))
    batch_skipped=$step_skip  # only count final skips (retries may fix earlier skips)
    new_ids=$(echo "$result" | grep "^  OK " | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
    if [ -n "$new_ids" ]; then
      batch_sh_ids="${batch_sh_ids:+${batch_sh_ids},}${new_ids}"
    fi

    # If no failures or no more retries, done with this batch
    if [ ! -s "$failures_json" ] || [ "$attempt" -gt "$max_retries" ]; then
      break
    fi

    num_failures=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).length' "$failures_json")
    echo "    Retrying $num_failures failed items (attempt $((attempt + 1))/$((max_retries + 1)))..."

    # Build retry prompt with feedback about what went wrong
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
      puts "{ \"sh_id\", \"code\", \"shells\", \"name\", \"summary\", \"rationale\", \"example_script\", \"requires_dataflow\" }"
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
      -c model_reasoning_effort="\"$reasoning\"" \
      -c web_search='"disabled"' \
      --output-schema "$schema_path" \
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

  # Reconcile provenance hashes before verification
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

rm -f "$code_lines_tsv"

echo ""
echo "==> Done. $total_created artifacts created, $total_skipped skipped."
