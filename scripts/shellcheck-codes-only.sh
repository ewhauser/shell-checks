#!/bin/sh
# Wrapper around shellcheck that strips diagnostic messages from the output,
# leaving only numeric codes. This prevents LLMs from seeing (and
# inadvertently reusing) ShellCheck's own wording.
#
# Usage: shellcheck-codes-only.sh -s <shell> <file>
#
# Passes all arguments through to shellcheck with --norc -f json1,
# then reduces each comment object to { code, line, column, endLine,
# endColumn, level } — no "message" or "fix" fields.

set -eu

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck is required" >&2
  exit 1
fi

if ! command -v ruby >/dev/null 2>&1; then
  echo "ruby is required" >&2
  exit 1
fi

json_output=$(mktemp)
trap 'rm -f "$json_output"' EXIT HUP INT TERM

set +e
shellcheck --norc -f json1 "$@" >"$json_output"
sc_exit=$?
set -e

case "$sc_exit" in
  0|1) ;;
  *)
    cat "$json_output" >&2
    exit "$sc_exit"
    ;;
esac

ruby -rjson -e '
  payload = JSON.parse(File.read(ARGV[0]))
  comments = payload.fetch("comments", []).map { |c|
    {
      "code"      => c.fetch("code"),
      "line"      => c.fetch("line"),
      "column"    => c.fetch("column"),
      "endLine"   => c.fetch("endLine"),
      "endColumn" => c.fetch("endColumn"),
      "level"     => c.fetch("level")
    }
  }
  puts JSON.pretty_generate("comments" => comments)
' "$json_output"

exit "$sc_exit"
