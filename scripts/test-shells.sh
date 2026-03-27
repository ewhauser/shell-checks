#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

# Shells to test against (shellcheck -s supports: sh, bash, dash, ksh)
SHELLS="sh bash dash ksh"

# Check prerequisites
for s in $SHELLS; do
  if ! command -v "$s" >/dev/null 2>&1; then
    echo "Required shell not found: $s" >&2
    echo "Install it before running this script." >&2
    exit 1
  fi
done

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck is required" >&2
  exit 1
fi

ruby -ryaml -rjson -e '
  root = ARGV[0]
  shells = ARGV[1].split(" ")

  mappings_file = File.join(root, "mappings/shellcheck.yaml")
  mappings_data = YAML.load_file(mappings_file)
  known_file = File.join(root, "discovery/known-codes.yaml")
  known_data = YAML.load_file(known_file)

  total = mappings_data["mappings"].length
  updated = 0

  mappings_data["mappings"].each_with_index do |mapping, idx|
    sh_id = mapping.fetch("sh_id")
    example = mapping.fetch("example")
    expected_code = mapping.fetch("shellcheck_code")
    example_path = File.join(root, example)

    unless File.exist?(example_path)
      $stderr.puts "  SKIP #{sh_id}: missing example #{example}"
      next
    end

    matching_shells = []
    shells.each do |shell|
      out = `shellcheck --norc -s #{shell} -f json1 #{example_path} 2>/dev/null`
      begin
        data = JSON.parse(out)
        codes = data.fetch("comments", []).map { |c| c.fetch("code") }.uniq
        matching_shells << shell if codes.include?(expected_code)
      rescue
        next
      end
    end

    if matching_shells.empty?
      $stderr.puts "  WARN #{sh_id}: code #{expected_code} did not trigger under any shell"
      next
    end

    old_shells = Array(mapping["shells"])
    if old_shells.sort != matching_shells.sort
      mapping["shells"] = matching_shells
      updated += 1
      $stderr.puts "  #{sh_id}: #{old_shells.join(",")} -> #{matching_shells.join(",")}"
    end

    # Update corresponding rule file
    rule_path = File.join(root, "rules/#{sh_id}.yaml")
    if File.exist?(rule_path)
      text = File.read(rule_path)
      old_block = text[/^shells:\n(?:- .+\n)+/]
      if old_block
        new_block = "shells:\n" + matching_shells.map { |s| "- #{s}\n" }.join
        text.sub!(old_block, new_block)
        File.write(rule_path, text)
      end
    end
  end

  # Update known-codes shells by aggregating across all mappings for each code
  code_shells = {}
  mappings_data["mappings"].each do |m|
    code = m["shellcheck_code"]
    code_shells[code] ||= []
    code_shells[code] |= Array(m["shells"])
  end

  known_data["known_codes"].each do |entry|
    code = entry["shellcheck_code"]
    if code_shells[code]
      entry["shells"] = code_shells[code].sort
    end
  end

  File.write(mappings_file, YAML.dump(mappings_data))
  File.write(known_file, YAML.dump(known_data))

  $stderr.puts ""
  $stderr.puts "Tested #{total} mappings against #{shells.length} shells, updated #{updated}"
' "$root_dir" "$SHELLS"
