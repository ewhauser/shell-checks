#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
known_codes_path="$root_dir/discovery/known-codes.yaml"
results_path="$root_dir/discovery/github-search-results.yaml"

# GitHub code search rate limits are tight (~10 requests/minute for
# unauthenticated, 30/min authenticated).  We throttle accordingly.
THROTTLE_SECS=3

# Maximum results per query (gh search code caps at 100)
LIMIT=100

# Repos to exclude — ShellCheck itself and known forks.
# Matches are substring-checked against "owner/repo".
BLOCKED="
koalaman/shellcheck
vscode-shellcheck
shellcheck-py
"

usage() {
  cat <<'EOF'
Usage: ./scripts/github-discover.sh [-n] [-l LIMIT]

Search GitHub for ShellCheck codes referenced in public repositories
(disable directives, .shellcheckrc files, CI configs) and report codes
not yet in discovery/known-codes.yaml.

  -n         Dry run — print queries but do not execute
  -l LIMIT   Max results per query (default: 100, max: 100)
  -h         Show this help
EOF
  exit 0
}

dry_run=false
while getopts "nl:h" opt; do
  case "$opt" in
    n) dry_run=true ;;
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

# Verify gh is authenticated
if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is not authenticated — run 'gh auth login' first" >&2
  exit 1
fi

raw_tmp=$(mktemp)
trap 'rm -f "$raw_tmp"' EXIT HUP INT TERM

# ── Search queries ────────────────────────────────────────────────
# Each query targets a different way SC codes appear in the wild.
# We collect raw JSON from each, then merge and deduplicate.
run_search() {
  query="$1"
  label="$2"
  extra_flags="${3:-}"

  if [ "$dry_run" = true ]; then
    echo "[dry-run] gh search code $query $extra_flags --limit $LIMIT"
    return
  fi

  echo "==> Searching: $label"
  # shellcheck disable=SC2086
  gh search code "$query" $extra_flags \
    --limit "$LIMIT" \
    --json textMatches,repository,path 2>/dev/null >> "$raw_tmp" || true

  sleep "$THROTTLE_SECS"
}

# 1. Inline disable directives in shell scripts
run_search "shellcheck disable=SC" "inline disable directives (shell)" "--language shell"

# 2. .shellcheckrc files
run_search "disable=SC" ".shellcheckrc files" "--filename .shellcheckrc"

# 3. Disable directives in Dockerfiles (common for embedded shell)
run_search "shellcheck disable=SC" "Dockerfiles" "--language dockerfile"

# 4. CI configs that pass --exclude to shellcheck
run_search "shellcheck --exclude" "CI exclude flags" "--language yaml"

# 5. GitHub Actions workflows referencing SC codes
run_search "shellcheck SC" "GitHub Actions workflows" "--filename .yml --match file"

if [ "$dry_run" = true ]; then
  exit 0
fi

echo ""
echo "==> Extracting codes from search results..."

# ── Parse results and produce report ──────────────────────────────
ruby -ryaml -rjson -rset -e '
  raw_path = ARGV[0]
  known_codes_path = ARGV[1]
  results_path = ARGV[2]
  blocked_raw = ARGV[3]

  blocked = blocked_raw.strip.split(/\s+/).reject(&:empty?)

  # Load known codes
  known_data = YAML.load_file(known_codes_path)
  known = Set.new(Array(known_data.fetch("known_codes", [])).map { |e| e.fetch("shellcheck_code").to_i })

  # Parse all JSON arrays from the raw dump.
  # gh search code outputs a JSON array per invocation; we concatenated them.
  results = []
  raw = File.read(raw_path)
  raw.scan(/\[.*?\](?=\s*\[|\s*\z)/m).each do |chunk|
    begin
      results.concat(JSON.parse(chunk))
    rescue JSON::ParserError
      # skip malformed fragments
    end
  end

  # Extract SC codes, source info, and text fragments
  code_sources = Hash.new { |h, k| h[k] = [] }
  code_fragments = Hash.new { |h, k| h[k] = [] }

  results.each do |item|
    repo = item.dig("repository", "nameWithOwner").to_s
    # Skip blocked repos
    next if blocked.any? { |b| repo.downcase.include?(b.downcase) }

    path = item.fetch("path", "")
    Array(item.fetch("textMatches", [])).each do |tm|
      fragment = tm.fetch("fragment", "")
      # Extract all SC\d{4,5} codes from the fragment
      fragment.scan(/SC(\d{4,5})/).flatten.each do |code_str|
        code = code_str.to_i
        source = "#{repo}/#{path}"
        code_sources[code] << source unless code_sources[code].include?(source)
        # Store unique text fragments (up to 3 per code) as contextual hints
        trimmed = fragment.strip
        unless trimmed.empty? || code_fragments[code].include?(trimmed) || code_fragments[code].length >= 3
          code_fragments[code] << trimmed
        end
      end
    end
  end

  all_codes = code_sources.keys.sort
  new_codes = all_codes.reject { |c| known.include?(c) }
  already_known = all_codes.select { |c| known.include?(c) }

  result = {
    "search_date" => Time.now.strftime("%Y-%m-%d"),
    "total_codes_found" => all_codes.length,
    "already_known_count" => already_known.length,
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
    "already_known" => already_known
  }

  File.write(results_path, YAML.dump(result))

  puts "==> Found #{all_codes.length} unique codes across all searches"
  puts "==> #{already_known.length} already known"
  puts "==> #{new_codes.length} NEW codes not in known-codes.yaml"
  if new_codes.any?
    puts ""
    puts "New codes:"
    new_codes.each do |c|
      refs = code_sources[c].length
      example = code_sources[c].first
      puts "  SC#{c}  (#{refs} ref#{"s" if refs != 1})  e.g. #{example}"
    end
  end
' "$raw_tmp" "$known_codes_path" "$results_path" "$BLOCKED"

echo ""
echo "==> Results written to discovery/github-search-results.yaml"
