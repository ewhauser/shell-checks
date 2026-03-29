#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

ruby - "$root_dir" <<'RUBY'
require "digest"
require "find"
require "yaml"

root = ARGV.fetch(0)
errors = []
shared_index_files = [
  "mappings/shellcheck.yaml",
  "discovery/known-codes.yaml"
]
artifact_session_prefixes = [
  "examples/",
  "rules/",
  "provenance/artifacts/"
]
prompt_session_prefix = "provenance/prompts/"
corpus_task_summary = "Create clean-room artifact bundles for corpus-discovered ShellCheck codes."
corpus_source_class = "Non-ShellCheck third-party shell scripts or corpus-derived hints used to identify numeric codes or likely triggering constructs"
corpus_discovery_phrase = "identified via corpus scanning"
# Sessions through session-053 predate prompt-artifact recording.
legacy_prompt_hash_max_session = 53

def sha256(path)
  Digest::SHA256.file(path).hexdigest
end

def session_number(session_id)
  match = session_id.to_s.match(/\Asession-(\d+)\z/)
  match && match[1].to_i
end

def canonical_prompt_metadata(session)
  lines = []
  lines << "session_id=#{session.fetch("session_id")}"
  lines << "date=#{session.fetch("date")}"
  lines << "tool=#{session.fetch("tool")}"
  lines << "model=#{session.fetch("model")}"
  lines << "task_summary=#{session.fetch("task_summary")}"
  Array(session.fetch("allowed_source_classes")).each do |value|
    lines << "allowed_source_class=#{value}"
  end
  Array(session.fetch("generated_files")).each do |value|
    lines << "generated_file=#{value}"
  end
  lines.join("\n") + "\n"
end

def canonical_output(session, root)
  Array(session.fetch("generated_files")).sort.map do |relative|
    path = File.join(root, relative)
    raise "missing generated file #{relative}" unless File.file?(path)
    "#{relative}\t#{sha256(path)}"
  end.join("\n") + "\n"
end

def canonical_prompt_files(session, root)
  Array(session.fetch("prompt_files")).sort.map do |relative|
    path = File.join(root, relative)
    raise "missing prompt file #{relative}" unless File.file?(path)
    "#{relative}\t#{sha256(path)}"
  end.join("\n") + "\n"
end

ai_dir = File.join(root, "provenance", "ai-sessions")
artifact_dir = File.join(root, "provenance", "artifacts")
session_paths = Dir[File.join(ai_dir, "*.yaml")].sort
artifact_paths = Dir[File.join(artifact_dir, "*.yaml")].sort

errors << "missing provenance/ai-sessions records" if session_paths.empty?
errors << "missing provenance/artifacts records" if artifact_paths.empty?

sessions = {}

session_paths.each do |path|
  session = YAML.load_file(path, permitted_classes: [Date])
  session_id = session["session_id"].to_s
  if session_id.empty?
    errors << "#{path}: missing session_id"
    next
  end

  sessions[session_id] = session
  session_num = session_number(session_id)

  %w[date tool model task_summary prompt_sha256 output_sha256].each do |key|
    errors << "#{path}: missing #{key}" if session[key].to_s.empty?
  end

  unless Array(session["allowed_source_classes"]).any?
    errors << "#{path}: allowed_source_classes must be non-empty"
  end

  allowed_sources = Array(session["allowed_source_classes"])
  task_summary = session["task_summary"].to_s
  if task_summary == corpus_task_summary
    unless allowed_sources.include?(corpus_source_class)
      errors << "#{path}: corpus task_summary must include the canonical corpus source class"
    end
  elsif allowed_sources.include?(corpus_source_class)
    errors << "#{path}: non-corpus task_summary must not include the canonical corpus source class"
  end

  prompt_files = Array(session["prompt_files"])
  if prompt_files.any?
    invalid_prompt_paths = prompt_files.reject { |rel| rel.start_with?(prompt_session_prefix) }
    if invalid_prompt_paths.any?
      errors << "#{path}: prompt_files must live under #{prompt_session_prefix} (#{invalid_prompt_paths.join(", ")})"
    end

    foreign_prompt_paths = prompt_files.reject { |rel| rel.start_with?("#{prompt_session_prefix}#{session_id}/") }
    if foreign_prompt_paths.any?
      errors << "#{path}: prompt_files must be namespaced under #{prompt_session_prefix}#{session_id}/ (#{foreign_prompt_paths.join(", ")})"
    end
  elsif session_num && session_num > legacy_prompt_hash_max_session
    errors << "#{path}: prompt_files must be non-empty for session-054 and later"
  end

  gen_files = Array(session["generated_files"])

  unless gen_files.any?
    errors << "#{path}: generated_files must be non-empty"
  end

  shared_generated = gen_files & shared_index_files
  if shared_generated.any?
    errors << "#{path}: generated_files must not include shared index files (#{shared_generated.join(", ")})"
  end

  non_artifact_generated = gen_files.reject do |rel|
    artifact_session_prefixes.any? { |prefix| rel.start_with?(prefix) }
  end
  if non_artifact_generated.any?
    errors << "#{path}: generated_files must only include artifact-specific outputs (#{non_artifact_generated.join(", ")})"
  end

  # Sessions created after the batch-size policy (2026-03-28) are capped at 15 files
  if session["date"].to_s >= "2026-03-29" && gen_files.length > 15
    errors << "#{path}: generated_files exceeds session size cap of 15 (has #{gen_files.length})"
  end

  unless session["prompt_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
    errors << "#{path}: prompt_sha256 must be a 64-character hex digest"
  end

  unless session["output_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
    errors << "#{path}: output_sha256 must be a 64-character hex digest"
  end

  begin
    prompt_digest = if prompt_files.any?
      Digest::SHA256.hexdigest(canonical_prompt_files(session, root))
    else
      Digest::SHA256.hexdigest(canonical_prompt_metadata(session))
    end
    if session["prompt_sha256"] != prompt_digest
      errors << "#{path}: prompt_sha256 does not match canonical prompt inputs"
    end
  rescue KeyError => e
    errors << "#{path}: #{e.message}"
  end

  begin
    output_digest = Digest::SHA256.hexdigest(canonical_output(session, root))
    if session["output_sha256"] != output_digest
      errors << "#{path}: output_sha256 does not match generated file hashes"
    end
  rescue StandardError => e
    errors << "#{path}: #{e.message}"
  end
end

artifact_paths.each do |path|
  artifact = YAML.load_file(path, permitted_classes: [Date])

  %w[artifact_id created_at clean_room_statement].each do |key|
    errors << "#{path}: missing #{key}" if artifact[key].to_s.empty?
  end

  file_entries = Array(artifact["files"])
  if file_entries.empty?
    errors << "#{path}: files must be non-empty"
  end

  shared_tracked = file_entries.map { |entry|
    rel = entry["path"].to_s
    shared_index_files.include?(rel) ? rel : nil
  }.compact
  if shared_tracked.any?
    errors << "#{path}: files must not include shared index files (#{shared_tracked.join(", ")})"
  end

  source_basis = Array(artifact["source_basis"])
  errors << "#{path}: source_basis must be non-empty" if source_basis.empty?

  source_basis.each do |entry|
    if entry =~ /\bcode\s+\d{3,}/
      errors << "#{path}: source_basis must not reference numeric codes (found: #{entry[0..80]})"
    end
  end

  ai_sessions = Array(artifact["ai_sessions"])
  errors << "#{path}: ai_sessions must be non-empty" if ai_sessions.empty?

  ai_sessions.each do |session_id|
    session = sessions[session_id]
    if session.nil?
      errors << "#{path}: missing ai session #{session_id}"
      next
    end

    generated = Array(session["generated_files"])
    file_entries.each do |entry|
      rel = entry["path"].to_s
      next if rel.empty?
      unless generated.include?(rel)
        errors << "#{path}: #{rel} is not listed in AI session #{session_id}"
      end
    end

    if artifact["clean_room_statement"].to_s.include?(corpus_discovery_phrase)
      task_summary = session["task_summary"].to_s
      allowed_sources = Array(session["allowed_source_classes"])
      unless task_summary == corpus_task_summary && allowed_sources.include?(corpus_source_class)
        errors << "#{path}: corpus-discovered artifact must reference a corpus-compliant AI session (#{session_id})"
      end
    end
  end

  file_entries.each do |entry|
    rel = entry["path"].to_s
    expected = entry["sha256"].to_s

    if rel.empty?
      errors << "#{path}: file entry missing path"
      next
    end

    unless expected.match?(/\A[0-9a-f]{64}\z/)
      errors << "#{path}: #{rel} has an invalid sha256"
      next
    end

    file_path = File.join(root, rel)
    unless File.file?(file_path)
      errors << "#{path}: missing tracked file #{rel}"
      next
    end

    actual = sha256(file_path)
    if actual != expected
      errors << "#{path}: hash mismatch for #{rel}"
    end
  end

  oracle = artifact["oracle"] || {}
  %w[tool version command expected_code].each do |key|
    errors << "#{path}: oracle missing #{key}" if oracle[key].to_s.empty?
  end
end

if errors.empty?
  puts "provenance verification passed"
else
  errors.each { |error| warn error }
  exit 1
end
RUBY
