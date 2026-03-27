#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
scripts_dir="$root_dir/corpus/scripts"
known_codes_path="$root_dir/discovery/known-codes.yaml"
results_path="$root_dir/corpus/scan-results.yaml"
codes_tmp=$(mktemp)
trap 'rm -f "$codes_tmp"' EXIT HUP INT TERM

# Default parallelism
jobs=4
timeout_secs=10

usage() {
  echo "Usage: $0 [-j jobs] [-t timeout]"
  echo "  -j JOBS     Parallel jobs (default: $jobs)"
  echo "  -t TIMEOUT  Per-file timeout in seconds (default: $timeout_secs)"
  exit 1
}

while getopts "j:t:h" opt; do
  case "$opt" in
    j) jobs="$OPTARG" ;;
    t) timeout_secs="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [ ! -d "$scripts_dir" ]; then
  echo "No corpus found at $scripts_dir — run corpus-download.sh first" >&2
  exit 1
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck is required" >&2
  exit 1
fi

sc_version=$(shellcheck --version | grep '^version:' | awk '{print $2}')
echo "==> ShellCheck version: $sc_version"

corpus_size=$(find "$scripts_dir" -type f | wc -l | tr -d ' ')
echo "==> Scanning $corpus_size files with $jobs parallel jobs..."

# Create a helper script for xargs to call per-file.
# It detects the shell dialect, runs shellcheck, and outputs "code\tfilename" lines.
scan_helper=$(mktemp)
trap 'rm -f "$codes_tmp" "$scan_helper"' EXIT HUP INT TERM
cat > "$scan_helper" <<'HELPER'
#!/bin/sh
file="$1"
timeout_secs="$2"
basename=$(basename "$file")

# Detect shell from shebang
shebang=$(head -1 "$file" 2>/dev/null || true)
case "$shebang" in
  *bash*)  shell="bash" ;;
  *ksh*)   shell="ksh" ;;
  *zsh*)   shell="zsh" ;;
  *dash*)  shell="sh" ;;
  *sh*)    shell="sh" ;;
  *)       shell="sh" ;;
esac

# Run shellcheck, extract only numeric codes
timeout "$timeout_secs" shellcheck --norc -s "$shell" -f json1 "$file" 2>/dev/null | \
  ruby -rjson -e '
    begin
      data = JSON.parse($stdin.read)
      data.fetch("comments", []).each { |c| puts "#{c.fetch("code")}\t'"$basename"'" }
    rescue
    end
  ' 2>/dev/null || true
HELPER
chmod +x "$scan_helper"

# Run in parallel with xargs (null-delimited to handle special chars in filenames)
find "$scripts_dir" -type f -print0 | \
  xargs -0 -P "$jobs" -I {} "$scan_helper" {} "$timeout_secs" >> "$codes_tmp"

echo "==> Scan complete. Processing results..."

# Build results YAML using ruby
ruby -ryaml -rset -e '
  codes_file = ARGV[0]
  known_codes_path = ARGV[1]
  sc_version = ARGV[2]
  corpus_size = ARGV[3].to_i
  results_path = ARGV[4]

  # Load known codes
  known_data = YAML.load_file(known_codes_path)
  known = Set.new(Array(known_data.fetch("known_codes", [])).map { |e| e.fetch("shellcheck_code").to_i })

  # Parse code -> files mapping
  code_files = Hash.new { |h, k| h[k] = [] }
  code_counts = Hash.new(0)
  File.readlines(codes_file).each do |line|
    parts = line.strip.split("\t")
    next if parts.length < 2
    code = parts[0].to_i
    file = parts[1]
    code_counts[code] += 1
    code_files[code] << file unless code_files[code].include?(file)
  end

  all_codes = code_counts.keys.sort
  new_codes = all_codes.reject { |c| known.include?(c) }

  result = {
    "scan_date" => Time.now.strftime("%Y-%m-%d"),
    "shellcheck_version" => sc_version,
    "corpus_size" => corpus_size,
    "total_unique_codes" => all_codes.length,
    "new_code_count" => new_codes.length,
    "all_codes" => all_codes,
    "new_codes" => new_codes,
    "code_details" => {}
  }

  new_codes.each do |code|
    result["code_details"][code] = {
      "count" => code_counts[code],
      "example_files" => code_files[code].first(5)
    }
  end

  File.write(results_path, YAML.dump(result))

  puts "==> Found #{all_codes.length} unique codes"
  puts "==> #{new_codes.length} new codes (not in known-codes.yaml)"
  if new_codes.any?
    puts "==> New codes found:"
    new_codes.each { |c| puts "    #{c}" }
  end
' "$codes_tmp" "$known_codes_path" "$sc_version" "$corpus_size" "$results_path"

echo ""
echo "==> Results written to corpus/scan-results.yaml"
