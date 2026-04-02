#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
known_codes_path="$root_dir/discovery/known-codes.yaml"
mappings_path="$root_dir/mappings/shellcheck.yaml"
issues_dir="$root_dir/issues"

model="${CODEX_MODEL:-gpt-5.4-mini}"
reasoning="${CODEX_REASONING:-medium}"
batch_size=5
extra_examples=2

usage() {
  cat <<'EOF'
Usage: ./scripts/issue-enrich-rules.sh [-m model] [-r reasoning] [-b batch_size] [-s start_offset] [-n max_rules] [-c codes] [-e extra_examples]

Enrich existing rules using context from GitHub issues:
  - Improve rule names, summaries, and rationales
  - Generate additional example scripts showing different trigger patterns

Reads issues/ for context and updates rules/ YAML files. New examples are
verified against the oracle before being added.

  -m MODEL           Model for codex (default: gpt-5.4-mini)
  -r REASONING       Reasoning effort: low|medium|high (default: medium)
  -b BATCH_SIZE      Rules per batch (default: 5)
  -s OFFSET          Skip first N rules (default: 0)
  -n MAX_RULES       Maximum total rules to process (default: all)
  -c CODES           Comma-separated list of specific SC codes to enrich (e.g., 2086,2034)
  -e EXTRA_EXAMPLES  Number of additional examples per rule (default: 2)
EOF
  exit 1
}

start_offset=0
max_rules=0
filter_codes=""
while getopts "m:r:b:s:n:c:e:h" opt; do
  case "$opt" in
    m) model="$OPTARG" ;;
    r) reasoning="$OPTARG" ;;
    b) batch_size="$OPTARG" ;;
    s) start_offset="$OPTARG" ;;
    n) max_rules="$OPTARG" ;;
    c) filter_codes="$OPTARG" ;;
    e) extra_examples="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

today=$(date +%Y-%m-%d)
sc_version=$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("shellcheck_version")' "$known_codes_path")

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

# -------------------------------------------------------------------
# Phase 1: Build enrichment candidates with issue context
# -------------------------------------------------------------------

echo "==> Phase 1: Collecting rules with issue context..."

enrich_json="$tmpdir/enrich_input.json"

ruby -ryaml -rjson -e '
  mappings = YAML.load_file(ARGV[0])
  issues_dir = ARGV[1]
  filter = ARGV[2].to_s.split(",").map(&:to_i).reject(&:zero?)
  root = ARGV[3]

  # Build SC code -> issue files index
  issue_index = Hash.new { |h, k| h[k] = [] }
  Dir[File.join(issues_dir, "*.md")].sort.each do |f|
    num = File.basename(f, ".md").to_i
    content = File.read(f)
    content.scan(/SC(\d{4})\b/).flatten.each do |code|
      issue_index[code.to_i] << { num: num, content: content }
    end
  end

  candidates = []

  Array(mappings["mappings"]).each do |entry|
    code = entry["shellcheck_code"]
    sh_id = entry["sh_id"]
    shells = Array(entry["shells"])
    next if filter.any? && !filter.include?(code)
    next unless issue_index.key?(code)

    rule_path = File.join(root, "rules", "#{sh_id}.yaml")
    next unless File.file?(rule_path)
    rule = YAML.load_file(rule_path)

    example_path = File.join(root, rule["example"].to_s)
    existing_example = File.file?(example_path) ? File.read(example_path) : ""

    issues = issue_index[code].sort_by { |i| i[:num] }

    # Extract context: titles, snippets, descriptions
    context_parts = []
    issue_snippets = []
    issues.first(5).each do |issue|
      content = issue[:content]
      num = issue[:num]

      # Title
      if content =~ /^# .* `\w+`: (.+)/
        context_parts << "Issue ##{num}: #{$1.strip}"
      end

      # Code blocks
      blocks = content.scan(/```(?:sh|bash|shell)?\n(.*?)```/m).flatten
      blocks.each do |block|
        stripped = block.strip
        next if stripped.length < 10 || stripped.length > 500
        issue_snippets << { issue: num, code: stripped }
      end

      # Description lines near the SC code mention
      content.lines.each_with_index do |line, idx|
        if line.match?(/SC#{code}\b/) && !line.match?(/e\.g\./) && !line.match?(/Rule Id/)
          desc = line.strip.gsub(/\s+/, " ")[0..200]
          context_parts << "Ref: #{desc}" unless desc.empty?
        end
      end
    end

    candidates << {
      code: code,
      sh_id: sh_id,
      shells: shells,
      name: rule["name"],
      summary: rule["summary"],
      rationale: rule["rationale"],
      existing_example: existing_example,
      requires_dataflow: rule["requires_dataflow"] || false,
      issue_count: issues.length,
      context: context_parts.first(8).join(" | "),
      snippets: issue_snippets.first(6)
    }
  end

  puts JSON.pretty_generate(candidates)
' "$mappings_path" "$issues_dir" "$filter_codes" "$root_dir" > "$enrich_json"

total_rules=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).length' "$enrich_json")
echo "    $total_rules rules have issue context for enrichment"

if [ "$total_rules" -eq 0 ]; then
  echo "==> No rules to enrich"
  exit 0
fi

# -------------------------------------------------------------------
# Phase 2: Batch processing loop
# -------------------------------------------------------------------

schema_path="$tmpdir/enrich-schema.json"
cat > "$schema_path" <<SCHEMA
{
  "type": "object",
  "properties": {
    "rules": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "sh_id": { "type": "string" },
          "code": { "type": "integer" },
          "name": { "type": "string", "description": "Improved kebab-case name" },
          "summary": { "type": "string", "description": "Improved one-sentence description" },
          "rationale": { "type": "string", "description": "Improved one-sentence recommendation" },
          "extra_examples": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "label": { "type": "string", "description": "Short label for this example variant (e.g. in-subshell, with-array)" },
                "shell": { "type": "string", "enum": ["sh", "bash", "dash", "ksh"] },
                "script": { "type": "string", "description": "Minimal shell script that triggers the same code via a different pattern" }
              },
              "required": ["label", "shell", "script"],
              "additionalProperties": false
            },
            "description": "Additional example scripts showing different trigger patterns for the same code"
          }
        },
        "required": ["sh_id", "code", "name", "summary", "rationale", "extra_examples"],
        "additionalProperties": false
      }
    }
  },
  "required": ["rules"],
  "additionalProperties": false
}
SCHEMA

echo "==> Phase 2: Enriching rules in batches of $batch_size..."

# Split candidates into batches
ruby -rjson -e '
  all = JSON.parse(File.read(ARGV[0]))
  offset = ARGV[1].to_i
  limit = ARGV[2].to_i
  batch_size = ARGV[3].to_i
  out_dir = ARGV[4]

  all = all[offset..] || []
  all = all.first(limit) if limit > 0

  all.each_slice(batch_size).each_with_index do |batch, idx|
    File.write(File.join(out_dir, "batch_#{idx}.json"), JSON.pretty_generate(batch))
  end
  puts all.length
' "$enrich_json" "$start_offset" "$max_rules" "$batch_size" "$tmpdir"

remaining=$(ls "$tmpdir"/batch_*.json 2>/dev/null | wc -l | tr -d ' ')
echo "    $remaining batches to process"

total_updated=0
total_examples_added=0
total_unchanged=0

for batch_file in "$tmpdir"/batch_*.json; do
  batch_num=$(basename "$batch_file" .json | sed 's/batch_//')
  batch_count=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).length' "$batch_file")

  echo ""
  echo "==> Batch $((batch_num + 1)): $batch_count rules"

  # Build prompt
  prompt_file="$tmpdir/prompt_enrich_${batch_num}.txt"
  ruby -rjson -e '
    candidates = JSON.parse(File.read(ARGV[0]))
    prompt_path = ARGV[1]
    extra_count = ARGV[2].to_i

    rules_block = []
    candidates.each do |c|
      rules_block << "- sh_id: #{c["sh_id"]}, code: #{c["code"]}, shells: [#{c["shells"].join(", ")}]"
      rules_block << "  Current name: #{c["name"]}"
      rules_block << "  Current summary: #{c["summary"]}"
      rules_block << "  Current rationale: #{c["rationale"]}"
      rules_block << "  Existing example:"
      c["existing_example"].lines.first(8).each { |l| rules_block << "    #{l.rstrip}" }
      rules_block << "  Issue context (#{c["issue_count"]} issues): #{c["context"]}"
      if c["snippets"] && !c["snippets"].empty?
        rules_block << "  Community snippets that trigger this code:"
        c["snippets"].first(4).each do |s|
          compressed = s["code"].gsub("\n", "\\u2424")[0..200]
          rules_block << "    Issue ##{s["issue"]}: #{compressed}"
        end
      end
      rules_block << ""
    end

    prompt = <<~PROMPT
      You are improving shell linting rules. For each rule below, you have the current
      description, the existing example, and context from community bug reports. Your job:

      1. IMPROVE DESCRIPTIONS: Write better name/summary/rationale using the real-world
         context from issues. The community context shows how this rule manifests in practice.

      2. GENERATE #{extra_count} ADDITIONAL EXAMPLES: Write #{extra_count} new minimal shell scripts
         that trigger the SAME shellcheck code but via DIFFERENT patterns or constructs than
         the existing example. Use the community snippets as inspiration for what patterns
         people encounter in practice, but write your own independent scripts.

      Rules to enrich:
      #{rules_block.join("\n")}

      Instructions:
      - summary and rationale must each be ONE sentence, in your own words
      - Do NOT reuse ShellCheck diagnostic wording or copy issue text verbatim
      - Do NOT include SC code numbers in text
      - Each extra_examples script MUST start with #!/bin/sh or #!/bin/bash as appropriate
      - Each extra example must trigger the SAME code but via a DIFFERENT pattern
      - Keep extra examples minimal (1-5 lines) and focused
      - If you need to suppress other warnings, use numeric codes (e.g. "# shellcheck disable=1072")
      - Set label to a short descriptor of what makes this example different
      - Do NOT run any commands or write any files
    PROMPT
    File.write(prompt_path, prompt)
  ' "$batch_file" "$prompt_file" "$extra_examples"

  # Get LLM response
  llm_output="$tmpdir/llm_enrich_${batch_num}.json"

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
    echo "    ERROR: codex produced no output, skipping batch"
    continue
  fi

  # Apply updates
  counts_file="$tmpdir/counts_${batch_num}.txt"
  ruby -rjson -ryaml -rdigest -e '
    root = ARGV[0]
    raw = File.read(ARGV[1])
    sc_version = ARGV[2]
    today = ARGV[3]
    counts_file = ARGV[4]

    data = JSON.parse(raw)
    rules = data.is_a?(Hash) ? data.fetch("rules") : data

    updated = 0
    unchanged = 0
    examples_added = 0

    # Determine next RB number for new examples
    existing_nums = Dir[File.join(root, "rules", "SH-*.yaml")].map { |f|
      File.basename(f, ".yaml").sub("SH-", "").to_i
    }.sort
    next_num = (existing_nums.last || 0) + 1

    # Load shared indexes for potential updates
    mappings_file = File.join(root, "mappings/shellcheck.yaml")
    mappings_data = YAML.load_file(mappings_file)

    rules.each do |rule|
      sh_id = rule["sh_id"]
      code = rule["code"]
      rule_path = File.join(root, "rules", "#{sh_id}.yaml")
      unless File.file?(rule_path)
        $stderr.puts "  SKIP #{sh_id}: rule file not found"
        next
      end

      existing = YAML.load_file(rule_path)
      changed = false

      new_name = rule["name"]
      new_summary = rule["summary"].gsub(/\bSC(\d{4,})/, "\\1")
      new_rationale = rule["rationale"].gsub(/\bSC(\d{4,})/, "\\1")

      if new_name != existing["name"] || new_summary != existing["summary"] || new_rationale != existing["rationale"]
        existing["name"] = new_name
        existing["summary"] = new_summary
        existing["rationale"] = new_rationale

        out = "id: #{existing["id"]}\n"
        out += "name: #{existing["name"]}\n"
        out += "summary: #{existing["summary"]}\n"
        out += "shells:\n"
        Array(existing["shells"]).each { |s| out += "- #{s}\n" }
        out += "example: #{existing["example"]}\n"
        out += "rationale: #{existing["rationale"]}\n"
        out += "requires_dataflow: true\n" if existing["requires_dataflow"]
        File.write(rule_path, out)
        changed = true
      end

      # Process extra examples
      Array(rule["extra_examples"]).each do |ex|
        script = ex["script"].gsub("\\n", "\n")
        script += "\n" unless script.end_with?("\n")
        shell = ex["shell"] || "sh"
        label = ex["label"] || "variant"

        padded = "%03d" % next_num
        example_path = "examples/#{padded}.sh"
        new_sh_id = "SH-#{padded}"
        full_path = File.join(root, example_path)

        File.write(full_path, script)
        File.chmod(0755, full_path)

        # Verify with shellcheck
        sc_out = `shellcheck --norc -s #{shell} -f json1 #{full_path} 2>/dev/null`
        begin
          sc_data = JSON.parse(sc_out)
          codes_found = sc_data.fetch("comments", []).map { |c| c.fetch("code") }.uniq
          unless codes_found.include?(code)
            $stderr.puts "  SKIP example #{new_sh_id} (#{label}): expected #{code}, got #{codes_found}"
            File.delete(full_path) rescue nil
            next
          end
        rescue => e
          $stderr.puts "  SKIP example #{new_sh_id}: shellcheck error: #{e}"
          File.delete(full_path) rescue nil
          next
        end

        # Create rule for the new example
        new_rule_path = File.join(root, "rules", "#{new_sh_id}.yaml")
        rule_yaml = "id: #{new_sh_id}\n"
        rule_yaml += "name: #{existing["name"]}-#{label}\n"
        rule_yaml += "summary: #{new_summary}\n"
        rule_yaml += "shells:\n- #{shell}\n"
        rule_yaml += "example: #{example_path}\n"
        rule_yaml += "rationale: #{new_rationale}\n"
        rule_yaml += "requires_dataflow: true\n" if existing["requires_dataflow"]
        File.write(new_rule_path, rule_yaml)

        # Add to mappings
        mappings_data["mappings"] << {
          "sh_id" => new_sh_id,
          "example" => example_path,
          "shellcheck_code" => code,
          "shells" => [shell],
          "shellcheck_version" => sc_version
        }

        $stderr.puts "  NEW #{new_sh_id} (#{label}): code #{code} verified"
        examples_added += 1
        next_num += 1
        changed = true
      end

      if changed
        updated += 1
        $stderr.puts "  UPDATED #{sh_id}" unless rule["extra_examples"]&.any?
      else
        unchanged += 1
        $stderr.puts "  UNCHANGED #{sh_id}"
      end
    end

    # Write updated mappings
    File.write(mappings_file, YAML.dump(mappings_data))

    File.write(counts_file, "#{updated} #{unchanged} #{examples_added}")
  ' "$root_dir" "$llm_output" "$sc_version" "$today" "$counts_file" 2>&1

  if [ -f "$counts_file" ]; then
    batch_updated=$(awk '{print $1}' "$counts_file")
    batch_unchanged=$(awk '{print $2}' "$counts_file")
    batch_examples=$(awk '{print $3}' "$counts_file")
    total_updated=$((total_updated + batch_updated))
    total_unchanged=$((total_unchanged + batch_unchanged))
    total_examples_added=$((total_examples_added + batch_examples))
    echo "    Batch $((batch_num + 1)): $batch_updated rules updated, $batch_examples examples added, $batch_unchanged unchanged"
  fi

  # Verify oracle still passes
  if ! "$root_dir/scripts/verify-oracle.sh" --strict >/dev/null 2>&1; then
    echo "    WARNING: Oracle verification issue after enrichment"
    "$root_dir/scripts/verify-oracle.sh" --strict 2>&1 | grep -iv "^verified" | head -5 >&2 || true
  fi
done

echo ""
echo "==> Done. $total_updated rules updated, $total_examples_added examples added, $total_unchanged unchanged."
