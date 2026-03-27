#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
known_codes_path="$root_dir/discovery/known-codes.yaml"

usage() {
  cat <<'EOF'
Usage: ./scripts/check-codes.sh <code> [<code> ...]

Look up one or more ShellCheck compatibility codes in discovery/known-codes.yaml.
Inputs may be bare numbers or SC-prefixed identifiers such as SC2086.

The command prints JSON:
{
  "shellcheck_version": "...",
  "codes": [
    {
      "query": "SC2086",
      "normalized_code": "2086",
      "known": true,
      "status": "covered",
      "shells": ["sh", "bash"],
      "sources": ["mappings/SH-001"],
      "rationale": "..."
    },
    {
      "query": "9999",
      "normalized_code": "9999",
      "known": false
    }
  ]
}
EOF
}

if [ "$#" -eq 0 ]; then
  usage >&2
  exit 1
fi

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

ruby -ryaml -rjson -e '
  data = YAML.load_file(ARGV.shift)
  version = data.fetch("shellcheck_version").to_s
  entries = Array(data.fetch("known_codes"))

  index = {}
  entries.each do |item|
    code = item.fetch("shellcheck_code").to_s
    index[code] = item
  end

  results = ARGV.map do |raw|
    normalized = raw.to_s.sub(/\ASC/i, "")
    unless normalized.match?(/\A\d+\z/)
      warn "invalid code query: #{raw.inspect}"
      exit 1
    end

    item = index[normalized]
    result = {
      "query" => raw,
      "normalized_code" => normalized,
      "known" => !item.nil?
    }
    next result unless item

    result.merge(
      "status" => item.fetch("status").to_s,
      "shells" => Array(item.fetch("shells")),
      "sources" => Array(item.fetch("sources")),
      "rationale" => item.fetch("rationale").to_s
    )
  end

  puts JSON.pretty_generate(
    "shellcheck_version" => version,
    "codes" => results
  )
' "$known_codes_path" "$@"
