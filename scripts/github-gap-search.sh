#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
known_codes_path="$root_dir/discovery/known-codes.yaml"
search_results_path="$root_dir/discovery/github-search-results.yaml"
results_path="$root_dir/discovery/github-gap-results.yaml"

THROTTLE_SECS=3
LIMIT=5

# Repos to exclude — ShellCheck itself and known forks.
BLOCKED="
koalaman/shellcheck
vscode-shellcheck
shellcheck-py
"

usage() {
  cat <<'EOF'
Usage: ./scripts/github-gap-search.sh [-n] [-r START-END] [-l LIMIT]

Search GitHub for ShellCheck codes in numeric gaps between known codes.
Outputs discovery/github-gap-results.yaml.

  -n           Dry run — print gap codes but do not search
  -r START-END Limit to a specific range (e.g., -r 1000-1100)
  -l LIMIT     Max results per query (default: 5)
  -h           Show this help
EOF
  exit 0
}

dry_run=false
range_start=0
range_end=0
while getopts "nr:l:h" opt; do
  case "$opt" in
    n) dry_run=true ;;
    r)
      range_start=$(echo "$OPTARG" | cut -d- -f1)
      range_end=$(echo "$OPTARG" | cut -d- -f2)
      ;;
    l) LIMIT="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI is required" >&2
  exit 1
fi

if ! command -v ruby >/dev/null 2>&1; then
  echo "error: ruby is required" >&2
  exit 1
fi

if [ "$dry_run" = false ]; then
  if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh is not authenticated — run 'gh auth login' first" >&2
    exit 1
  fi
fi

# Compute gap codes
gap_codes_file=$(mktemp)
trap 'rm -f "$gap_codes_file"' EXIT HUP INT TERM

ruby -ryaml -rset -rjson -e '
  known_path = ARGV[0]
  search_path = ARGV[1]
  range_start = ARGV[2].to_i
  range_end = ARGV[3].to_i
  results_path = ARGV[4]

  # Collect all known/seen codes
  seen = Set.new
  known_data = YAML.load_file(known_path)
  Array(known_data.fetch("known_codes", [])).each { |e| seen << e.fetch("shellcheck_code").to_i }

  # Also include codes from previous search results
  if File.file?(search_path)
    search_data = YAML.load_file(search_path)
    Array(search_data.fetch("new_codes", [])).each { |e| seen << e.fetch("code").to_i }
    Array(search_data.fetch("already_known", [])).each { |c| seen << c.to_i }
  end

  # Also include codes from previous gap results (for incremental operation)
  if File.file?(results_path)
    gap_data = YAML.load_file(results_path)
    Array(gap_data.fetch("new_codes", [])).each { |e| seen << e.fetch("code").to_i }
    Array(gap_data.fetch("already_searched", [])).each { |c| seen << c.to_i }
    Array(gap_data.fetch("no_results", [])).each { |c| seen << c.to_i }
  end

  # Define ranges: 1000-1999, 2000-2999, 3000-3999
  ranges = [[1000, 1999], [2000, 2999], [3000, 3999]]

  gaps = []
  ranges.each do |rmin, rmax|
    codes_in_range = seen.select { |c| c >= rmin && c <= rmax }.sort
    next if codes_in_range.empty?
    lo = codes_in_range.first
    hi = codes_in_range.last
    (lo..hi).each do |c|
      next if seen.include?(c)
      gaps << c
    end
  end

  # Apply user range filter if specified
  if range_start > 0 && range_end > 0
    gaps = gaps.select { |c| c >= range_start && c <= range_end }
  end

  gaps.sort.each { |c| puts c }
' "$known_codes_path" "$search_results_path" "$range_start" "$range_end" "$results_path" > "$gap_codes_file"

gap_count=$(wc -l < "$gap_codes_file" | tr -d ' ')
echo "==> Found $gap_count gap codes to search"

if [ "$gap_count" -eq 0 ]; then
  echo "==> No gaps to search"
  exit 0
fi

if [ "$dry_run" = true ]; then
  echo ""
  echo "Gap codes:"
  while IFS= read -r code; do
    echo "  SC$code"
  done < "$gap_codes_file"
  exit 0
fi

# Search each gap code on GitHub
raw_tmp=$(mktemp)
searched_codes=""
trap 'rm -f "$gap_codes_file" "$raw_tmp"' EXIT HUP INT TERM

searched=0
found=0
while IFS= read -r code; do
  searched=$((searched + 1))
  printf "  [%d/%d] Searching SC%s..." "$searched" "$gap_count" "$code"

  result=$(gh search code "SC${code}" \
    --language shell \
    --limit "$LIMIT" \
    --json textMatches,repository,path 2>/dev/null || echo "[]")

  # Quick check if any results
  hit_count=$(echo "$result" | ruby -rjson -e 'puts JSON.parse($stdin.read).length' 2>/dev/null || echo "0")

  if [ "$hit_count" -gt 0 ]; then
    echo "$result" >> "$raw_tmp"
    found=$((found + 1))
    printf " %s hits\n" "$hit_count"
  else
    printf " no results\n"
  fi

  searched_codes="${searched_codes}${searched_codes:+,}${code}"
  sleep "$THROTTLE_SECS"
done < "$gap_codes_file"

echo ""
echo "==> Searched $searched gap codes, found hits for $found"
echo "==> Extracting codes from results..."

# Parse results — same logic as github-discover.sh
ruby -ryaml -rjson -rset -e '
  raw_path = ARGV[0]
  known_codes_path = ARGV[1]
  results_path = ARGV[2]
  blocked_raw = ARGV[3]
  searched_raw = ARGV[4]

  blocked = blocked_raw.strip.split(/\s+/).reject(&:empty?)
  searched_codes = searched_raw.split(",").map(&:to_i).sort

  known_data = YAML.load_file(known_codes_path)
  known = Set.new(Array(known_data.fetch("known_codes", [])).map { |e| e.fetch("shellcheck_code").to_i })

  results = []
  if File.file?(raw_path) && File.size(raw_path) > 0
    raw = File.read(raw_path)
    raw.scan(/\[.*?\](?=\s*\[|\s*\z)/m).each do |chunk|
      begin
        results.concat(JSON.parse(chunk))
      rescue JSON::ParserError
      end
    end
  end

  code_sources = Hash.new { |h, k| h[k] = [] }
  code_fragments = Hash.new { |h, k| h[k] = [] }

  results.each do |item|
    repo = item.dig("repository", "nameWithOwner").to_s
    next if blocked.any? { |b| repo.downcase.include?(b.downcase) }

    path = item.fetch("path", "")
    Array(item.fetch("textMatches", [])).each do |tm|
      fragment = tm.fetch("fragment", "")
      fragment.scan(/SC(\d{4,5})/).flatten.each do |code_str|
        code = code_str.to_i
        # Only include codes we were searching for (gap codes)
        next unless searched_codes.include?(code)
        source = "#{repo}/#{path}"
        code_sources[code] << source unless code_sources[code].include?(source)
        trimmed = fragment.strip
        unless trimmed.empty? || code_fragments[code].include?(trimmed) || code_fragments[code].length >= 3
          code_fragments[code] << trimmed
        end
      end
    end
  end

  found_codes = code_sources.keys.sort
  new_codes = found_codes.reject { |c| known.include?(c) }
  no_result_codes = searched_codes - found_codes

  result = {
    "search_date" => Time.now.strftime("%Y-%m-%d"),
    "search_type" => "gap",
    "total_gaps_searched" => searched_codes.length,
    "codes_with_hits" => found_codes.length,
    "new_code_count" => new_codes.length,
    "new_codes" => new_codes.map { |c|
      entry = {
        "code" => c,
        "references" => code_sources[c].length,
        "example_sources" => code_sources[c].first(5)
      }
      entry["text_fragments"] = code_fragments[c] if code_fragments[c].any?
      entry
    },
    "already_searched" => (found_codes - new_codes).sort,
    "no_results" => no_result_codes
  }

  File.write(results_path, YAML.dump(result))

  puts "==> #{found_codes.length} gap codes had GitHub hits"
  puts "==> #{new_codes.length} NEW codes not in known-codes.yaml"
  puts "==> #{no_result_codes.length} gap codes had no results"
  if new_codes.any?
    puts ""
    puts "New codes:"
    new_codes.each do |c|
      refs = code_sources[c].length
      example = code_sources[c].first
      puts "  SC#{c}  (#{refs} ref#{"s" if refs != 1})  e.g. #{example}"
    end
  end
' "$raw_tmp" "$known_codes_path" "$results_path" "$BLOCKED" "$searched_codes"

echo ""
echo "==> Results written to discovery/github-gap-results.yaml"
