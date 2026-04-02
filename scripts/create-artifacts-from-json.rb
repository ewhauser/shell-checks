#!/usr/bin/env ruby
# Creates artifact files (rules, examples, provenance, mappings, known-codes,
# session record) from a JSON array produced by the LLM.
#
# Usage: ruby create-artifacts-from-json.rb ROOT SC_VERSION TODAY SESSION_ID MODEL JSON_PATH [FAILURES_PATH] [DISCOVERY_MODE] [PROMPT_SOURCES_PATH]
#
# If FAILURES_PATH is given, writes a JSON array of failed items (with actual
# codes found) so the caller can retry them.

require 'json'
require 'yaml'
require 'digest'
require 'fileutils'

root        = ARGV[0]
sc_version  = ARGV[1]
today       = ARGV[2]
session_id  = ARGV[3]
model       = ARGV[4]
json_path   = ARGV[5]
failures_path = ARGV[6]  # optional
prompt_sources_path = ARGV[8]  # optional newline-delimited list of prompt source files

BASE_ALLOWED_SOURCE_CLASSES = [
  "shell language manuals and semantic notes",
  "internally authored repository files",
  "shellcheck binary behavior observed through command-line runs"
].freeze

CORPUS_SOURCE_CLASS = "Non-ShellCheck third-party shell scripts or corpus-derived hints used to identify numeric codes or likely triggering constructs".freeze

GITHUB_SOURCE_CLASS = "Public GitHub code search references to numeric codes in non-ShellCheck repositories used to identify candidate compatibility codes".freeze

ISSUES_SOURCE_CLASS = "Community-authored GitHub issue content used as weak contextual hints for identifying candidate compatibility codes".freeze

DISCOVERY_MODES = {
  "corpus" => {
    "task_summary" => "Create clean-room artifact bundles for corpus-discovered ShellCheck codes.",
    "discovery_method" => "corpus scanning",
    "include_corpus_source_class" => true
  },
  "discover" => {
    "task_summary" => "Discover new ShellCheck compatibility codes and create clean-room artifact bundles.",
    "discovery_method" => "local oracle discovery",
    "include_corpus_source_class" => false
  },
  "synthetic" => {
    "task_summary" => "Discover new ShellCheck compatibility codes and create clean-room artifact bundles.",
    "discovery_method" => "synthetic bad-script generation",
    "include_corpus_source_class" => false
  },
  "github" => {
    "task_summary" => "Create clean-room artifact bundles for GitHub-search-discovered ShellCheck codes.",
    "discovery_method" => "GitHub public code search",
    "include_corpus_source_class" => false,
    "include_github_source_class" => true
  },
  "issues" => {
    "task_summary" => "Create clean-room artifact bundles for issue-discovered ShellCheck codes.",
    "discovery_method" => "GitHub issue mining of community-authored content",
    "include_corpus_source_class" => false,
    "include_issues_source_class" => true
  }
}.freeze

legacy_mode = {
  nil => "corpus",
  "" => "corpus",
  "corpus scanning" => "corpus",
  "local oracle discovery" => "discover",
  "synthetic bad-script generation" => "synthetic"
}

mode_key = ARGV[7]
discovery_mode = if DISCOVERY_MODES.key?(mode_key)
  mode_key
else
  legacy_mode.fetch(mode_key) do
    abort("Unknown discovery mode #{mode_key.inspect}; expected one of: #{DISCOVERY_MODES.keys.join(", ")}")
  end
end
mode_config = DISCOVERY_MODES.fetch(discovery_mode)
discovery_method = mode_config.fetch("discovery_method")
task_summary = mode_config.fetch("task_summary")
allowed = BASE_ALLOWED_SOURCE_CLASSES.dup
allowed << CORPUS_SOURCE_CLASS if mode_config.fetch("include_corpus_source_class")
allowed << GITHUB_SOURCE_CLASS if mode_config.fetch("include_github_source_class", false)
allowed << ISSUES_SOURCE_CLASS if mode_config.fetch("include_issues_source_class", false)

items = JSON.parse(File.read(json_path))
verified_items = []
failed_items = []

# ---------------------------------------------------------------
# Pass 1: Write examples, verify with shellcheck, write rules
# ---------------------------------------------------------------
items.each do |item|
  sh_id          = item.fetch("sh_id")
  code           = item.fetch("code")
  shells         = Array(item.fetch("shells"))
  shell          = shells.first
  name           = item.fetch("name")
  summary        = item.fetch("summary").gsub(/\bSC(\d{4,})/, '\1')
  rationale      = item.fetch("rationale").gsub(/\bSC(\d{4,})/, '\1')
  example_script = item.fetch("example_script")
  num            = sh_id.sub("SH-", "")

  example_path = "examples/#{num}.sh"
  rule_path    = "rules/#{sh_id}.yaml"

  # Write example script
  script_content = example_script.gsub("\\n", "\n")
  script_content += "\n" unless script_content.end_with?("\n")
  File.write(File.join(root, example_path), script_content)
  File.chmod(0755, File.join(root, example_path))

  # Verify with shellcheck — the target code must be present, and extra codes
  # should be minimized but are not an automatic failure.
  sc_out = `shellcheck --norc -s #{shell} -f json1 #{File.join(root, example_path)} 2>/dev/null`
  begin
    sc_data = JSON.parse(sc_out)
    codes_found = sc_data.fetch("comments", []).map { |c| c.fetch("code") }.uniq
    unless codes_found.include?(code)
      $stderr.puts "  SKIP #{sh_id}: expected code #{code} to be present, got #{codes_found}"
      File.delete(File.join(root, example_path)) rescue nil
      failed_items << item.merge("actual_codes" => codes_found)
      next
    end
    extra_codes = codes_found.reject { |found| found == code }
    unless extra_codes.empty?
      $stderr.puts "  NOTE #{sh_id}: extra codes also present: #{extra_codes.join(", ")}"
    end
  rescue => e
    $stderr.puts "  SKIP #{sh_id}: shellcheck parse error: #{e}"
    File.delete(File.join(root, example_path)) rescue nil
    failed_items << item.merge("actual_codes" => [], "error" => e.message)
    next
  end

  # Write rule spec
  requires_dataflow = item.fetch("requires_dataflow", false)
  shells_yaml = shells.map { |s| "- #{s}" }.join("\n")
  rule_yaml = "id: #{sh_id}\nname: #{name}\nsummary: #{summary}\nshells:\n#{shells_yaml}\nexample: #{example_path}\nrationale: #{rationale}\n"
  rule_yaml += "requires_dataflow: true\n" if requires_dataflow
  File.write(File.join(root, rule_path), rule_yaml)

  verified_items << item.merge("example_path" => example_path, "rule_path" => rule_path, "num" => num)
  $stderr.puts "  OK #{sh_id} (code #{code})"
end

if verified_items.empty?
  $stderr.puts "  No items passed verification."
  # Write failures so the caller can retry
  if failures_path && !failed_items.empty?
    File.write(failures_path, JSON.pretty_generate(failed_items))
  end
  exit 0
end

# ---------------------------------------------------------------
# Pass 2: Update shared indexes ONCE
# These files are repository-level state and are not tracked in per-artifact
# provenance manifests or per-session generated_files.
# ---------------------------------------------------------------
mappings_file = File.join(root, "mappings/shellcheck.yaml")
mappings_data = YAML.load_file(mappings_file)

known_file = File.join(root, "discovery/known-codes.yaml")
known_data = YAML.load_file(known_file)

verified_items.each do |item|
  mappings_data["mappings"] << {
    "sh_id"              => item["sh_id"],
    "example"            => item["example_path"],
    "shellcheck_code"    => item["code"],
    "shells"             => Array(item["shells"]),
    "shellcheck_version" => sc_version
  }

  known_data["known_codes"] << {
    "shellcheck_code" => item["code"],
    "status"          => "covered",
    "shells"          => Array(item["shells"]),
    "rationale"       => "Covered by #{item["sh_id"]}: #{item["summary"]}",
    "sources"         => ["mappings/#{item["sh_id"]}"]
  }
end

File.write(mappings_file, YAML.dump(mappings_data))
File.write(known_file, YAML.dump(known_data))

# ---------------------------------------------------------------
# Pass 3: Compute hashes and write provenance
# ---------------------------------------------------------------
verified_items.each do |item|
  sh_id        = item["sh_id"]
  code         = item["code"]
  shells       = Array(item["shells"])
  example_path = item["example_path"]
  rule_path    = item["rule_path"]

  rule_hash    = Digest::SHA256.file(File.join(root, rule_path)).hexdigest
  example_hash = Digest::SHA256.file(File.join(root, example_path)).hexdigest

  prov = {
    "artifact_id"          => sh_id,
    "created_at"           => today,
    "files"                => [
      { "path" => rule_path,                  "sha256" => rule_hash },
      { "path" => example_path,               "sha256" => example_hash }
    ],
    "source_basis"         => [
      "Shell semantics knowledge about the construct that triggers this diagnostic.",
      "Example independently authored, reduced, and checked so the target oracle code remains present with minimal extra diagnostics."
    ],
    "ai_sessions"          => [session_id],
    "oracle"               => {
      "tool"          => "shellcheck",
      "version"       => sc_version,
      "command"       => "shellcheck --norc -s #{shells.first} -f json1 #{example_path}",
      "expected_code" => code
    },
    "clean_room_statement" => "This artifact set was authored from shell semantics and local oracle " \
      "runs without reusing ShellCheck source, wiki text, or example snippets. " \
      "The numeric code was initially identified via #{discovery_method} but the " \
      "example script was independently authored."
  }
  prov_path = "provenance/artifacts/#{sh_id}.yaml"
  File.write(File.join(root, prov_path), YAML.dump(prov))
end

# ---------------------------------------------------------------
# Pass 4: Create session record with correct hashes
# ---------------------------------------------------------------
all_generated = []
verified_items.each do |item|
  all_generated << item["example_path"]
  all_generated << item["rule_path"]
  all_generated << "provenance/artifacts/#{item["sh_id"]}.yaml"
end
all_generated = all_generated.uniq.sort

prompt_sources = if prompt_sources_path && File.file?(prompt_sources_path)
  File.readlines(prompt_sources_path, chomp: true).map(&:strip).reject(&:empty?)
else
  []
end

prompt_files = []
if prompt_sources.any?
  prompt_dir = File.join(root, "provenance", "prompts", session_id)
  FileUtils.mkdir_p(prompt_dir)
  prompt_sources.each_with_index do |source_path, index|
    abort("Missing prompt source file #{source_path.inspect}") unless File.file?(source_path)
    ext = File.extname(source_path)
    ext = ".txt" if ext.empty?
    rel = "provenance/prompts/#{session_id}/prompt-#{format("%02d", index + 1)}#{ext}"
    FileUtils.cp(source_path, File.join(root, rel))
    prompt_files << rel
  end
end

# Compute prompt_sha256 from recorded prompt artifacts when available.
if prompt_files.any?
  prompt_manifest_lines = prompt_files.sort.map { |f|
    h = Digest::SHA256.file(File.join(root, f)).hexdigest
    "#{f}\t#{h}"
  }
  prompt_manifest_block = prompt_manifest_lines.join("\n") + "\n"
  prompt_sha = Digest::SHA256.hexdigest(prompt_manifest_block)
else
  meta_lines = []
  meta_lines << "session_id=#{session_id}"
  meta_lines << "date=#{today}"
  meta_lines << "tool=codex"
  meta_lines << "model=#{model}"
  meta_lines << "task_summary=#{task_summary}"
  allowed.each { |a| meta_lines << "allowed_source_class=#{a}" }
  all_generated.each { |f| meta_lines << "generated_file=#{f}" }
  meta_block = meta_lines.join("\n") + "\n"
  prompt_sha = Digest::SHA256.hexdigest(meta_block)
end

# Compute output_sha256 using ruby Digest
manifest_lines = all_generated.sort.map { |f|
  h = Digest::SHA256.file(File.join(root, f)).hexdigest
  "#{f}\t#{h}"
}
manifest_block = manifest_lines.join("\n") + "\n"
output_sha = Digest::SHA256.hexdigest(manifest_block)

session = {
  "session_id"             => session_id,
  "date"                   => today,
  "tool"                   => "codex",
  "model"                  => model,
  "task_summary"           => task_summary,
  "allowed_source_classes" => allowed,
  "generated_files"        => all_generated,
  "prompt_sha256"          => prompt_sha,
  "output_sha256"          => output_sha
}
session["prompt_files"] = prompt_files unless prompt_files.empty?
session_path = File.join(root, "provenance/ai-sessions/#{session_id}.yaml")
File.write(session_path, YAML.dump(session))

puts "Created #{verified_items.length} artifacts: #{verified_items.map { |i| i["sh_id"] }.join(', ')}"

# Write failures JSON if requested
if failures_path && !failed_items.empty?
  File.write(failures_path, JSON.pretty_generate(failed_items))
end
