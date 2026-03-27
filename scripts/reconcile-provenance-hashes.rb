#!/usr/bin/env ruby
# Reconciles provenance and session hashes while removing shared index files from
# per-artifact manifests and limiting session manifests to artifact-specific
# outputs.
#
# Usage: ruby reconcile-provenance-hashes.rb ROOT
#
# Updates:
# - provenance/artifacts/SH-*.yaml: strips shared index file entries, refreshes hashes
# - provenance/ai-sessions/session-*.yaml: strips shared indexes and mutable
#   infrastructure files from generated_files, refreshes prompt/output digests

require 'digest'
require 'yaml'

root = ARGV[0]
shared_index_files = [
  "mappings/shellcheck.yaml",
  "discovery/known-codes.yaml"
].freeze
artifact_session_prefixes = [
  "examples/",
  "rules/",
  "provenance/artifacts/"
].freeze
prompt_session_prefix = "provenance/prompts/".freeze
# Sessions through session-053 predate prompt-artifact recording.
legacy_prompt_hash_max_session = 53

def session_number(session_id)
  match = session_id.to_s.match(/\Asession-(\d+)\z/)
  match && match[1].to_i
end

# Update artifact provenance records with current file hashes
Dir[File.join(root, "provenance/artifacts/SH-*.yaml")].sort.each do |prov_path|
  prov_data = YAML.load_file(prov_path)
  files = Array(prov_data["files"])
  filtered_files = files.reject { |entry| shared_index_files.include?(entry["path"].to_s) }
  changed = filtered_files.length != files.length
  files = filtered_files
  prov_data["files"] = files
  files.each do |entry|
    rel = entry["path"].to_s
    next if rel.empty?
    full = File.join(root, rel)
    next unless File.file?(full)
    current_hash = Digest::SHA256.file(full).hexdigest
    if entry["sha256"] != current_hash
      entry["sha256"] = current_hash
      changed = true
    end
  end
  File.write(prov_path, YAML.dump(prov_data)) if changed
end

# Update session records' prompt_sha256 and output_sha256
Dir[File.join(root, "provenance/ai-sessions/session-*.yaml")].sort.each do |sess_path|
  sess = YAML.load_file(sess_path)
  session_id = sess["session_id"].to_s
  generated_files = Array(sess["generated_files"])
  filtered_generated = generated_files.reject { |rel|
    shared_index_files.include?(rel) || !artifact_session_prefixes.any? { |prefix| rel.start_with?(prefix) }
  }.uniq
  changed = filtered_generated != generated_files
  sess["generated_files"] = filtered_generated

  raw_prompt_files = Array(sess["prompt_files"])
  prompt_files = raw_prompt_files.uniq
  if prompt_files.any?
    if prompt_files != raw_prompt_files
      sess["prompt_files"] = prompt_files
      changed = true
    end
  end

  # Recompute prompt_sha256 from recorded prompt artifacts when available.
  begin
    if prompt_files.any?
      manifest_lines = prompt_files.sort.map do |rel|
        raise "missing prompt file #{rel}" unless File.file?(File.join(root, rel))
        raise "prompt file #{rel} must live under #{prompt_session_prefix}#{session_id}/" unless rel.start_with?("#{prompt_session_prefix}#{session_id}/")
        h = Digest::SHA256.file(File.join(root, rel)).hexdigest
        "#{rel}\t#{h}"
      end
      prompt_block = manifest_lines.join("\n") + "\n"
      new_prompt_sha = Digest::SHA256.hexdigest(prompt_block)
      if sess["prompt_sha256"] != new_prompt_sha
        sess["prompt_sha256"] = new_prompt_sha
        changed = true
      end
    elsif (session_number(session_id) || 0) <= legacy_prompt_hash_max_session
      lines = []
      lines << "session_id=#{sess.fetch("session_id")}"
      lines << "date=#{sess.fetch("date")}"
      lines << "tool=#{sess.fetch("tool")}"
      lines << "model=#{sess.fetch("model")}"
      lines << "task_summary=#{sess.fetch("task_summary")}"
      Array(sess.fetch("allowed_source_classes")).each { |v| lines << "allowed_source_class=#{v}" }
      Array(sess.fetch("generated_files")).each { |v| lines << "generated_file=#{v}" }
      prompt_block = lines.join("\n") + "\n"
      new_prompt_sha = Digest::SHA256.hexdigest(prompt_block)
      if sess["prompt_sha256"] != new_prompt_sha
        sess["prompt_sha256"] = new_prompt_sha
        changed = true
      end
    else
      $stderr.puts "  WARN: #{File.basename(sess_path)} is missing prompt_files; prompt_sha256 left unchanged"
    end
  rescue => e
    $stderr.puts "  WARN: Could not update prompt_sha256 for #{File.basename(sess_path)}: #{e.message}"
  end

  # Recompute output_sha256 from generated file manifest
  gen_files = Array(sess["generated_files"]).sort
  next if gen_files.empty?
  begin
    manifest_lines = gen_files.map { |f|
      h = Digest::SHA256.file(File.join(root, f)).hexdigest
      "#{f}\t#{h}"
    }
    manifest_block = manifest_lines.join("\n") + "\n"
    new_output_sha = Digest::SHA256.hexdigest(manifest_block)
    if sess["output_sha256"] != new_output_sha
      sess["output_sha256"] = new_output_sha
      changed = true
    end
  rescue => e
    $stderr.puts "  WARN: Could not update output_sha256 for #{File.basename(sess_path)}: #{e.message}"
  end

  File.write(sess_path, YAML.dump(sess)) if changed
end
