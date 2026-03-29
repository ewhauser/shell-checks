#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
mapping_file="$root_dir/mappings/shellcheck.yaml"

# Optional flags:
#   --only SH-001,SH-002,...  verify only specific artifacts
#   --strict                  warn when examples produce extra codes
only_filter=""
strict=false
while [ $# -gt 0 ]; do
  case "$1" in
    --only) only_filter="$2"; shift 2 ;;
    --strict) strict=true; shift ;;
    *) shift ;;
  esac
done

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck is required" >&2
  exit 1
fi

expected_version=$(
  ruby -ryaml -e '
    data = YAML.load_file(ARGV[0], permitted_classes: [Date])
    versions = Array(data.fetch("mappings")).map { |item| item.fetch("shellcheck_version").to_s }.uniq
    abort "mappings/shellcheck.yaml must declare exactly one shellcheck_version" unless versions.length == 1
    puts versions.first
  ' "$mapping_file"
)

installed_version=$(shellcheck --version | awk '/^version:/ { print $2 }')
if [ "$installed_version" != "$expected_version" ]; then
  echo "shellcheck version mismatch: expected $expected_version but found $installed_version" >&2
  exit 1
fi

mapping_rows=$(mktemp)
trap 'rm -f "$mapping_rows"' EXIT HUP INT TERM

ruby -ryaml -e '
  data = YAML.load_file(ARGV[0], permitted_classes: [Date])
  Array(data.fetch("mappings")).each do |item|
    shells = Array(item.fetch("shells")).join(",")
    fields = [
      item.fetch("sh_id"),
      item.fetch("example"),
      item.fetch("shellcheck_code").to_s,
      shells,
      item.fetch("shellcheck_version").to_s
    ]
    puts fields.join("\t")
  end
' "$mapping_file" >"$mapping_rows"

strict_warnings=0

while IFS="$(printf '\t')" read -r sh_id example expected_code shells_csv _declared_version; do
  [ -n "$sh_id" ] || continue

  # Skip if --only filter is set and this sh_id is not in the list
  if [ -n "$only_filter" ]; then
    case ",$only_filter," in
      *",$sh_id,"*) ;;
      *) continue ;;
    esac
  fi

  example_path="$root_dir/$example"

  if [ ! -f "$example_path" ]; then
    echo "missing example for $sh_id: $example" >&2
    exit 1
  fi

  # Verify against each shell in the list
  old_ifs="$IFS"
  IFS=","
  for shell in $shells_csv; do
    IFS="$old_ifs"

    json_output=$(mktemp)
    set +e
    shellcheck --norc -s "$shell" -f json1 "$example_path" >"$json_output"
    status=$?
    set -e

    case "$status" in
      0|1) ;;
      *)
        echo "shellcheck failed for $example (shell=$shell)" >&2
        cat "$json_output" >&2
        rm -f "$json_output"
        exit 1
        ;;
    esac

    actual_codes=$(
      ruby -rjson -e '
        payload = JSON.parse(File.read(ARGV[0]))
        codes = payload.fetch("comments", []).map { |comment| comment.fetch("code").to_i }.uniq.sort
        puts codes.join("\n")
      ' "$json_output"
    )
    rm -f "$json_output"

    if ! printf '%s\n' "$actual_codes" | grep -qx "$expected_code"; then
      echo "$sh_id expected code $expected_code to be present with -s $shell but got: $(printf '%s\n' "$actual_codes" | sed '/^$/d' | tr '\n' ' ')" >&2
      exit 1
    fi

    if "$strict"; then
      extra_codes=$(printf '%s\n' "$actual_codes" | sed '/^$/d' | grep -vx "$expected_code" || true)
      if [ -n "$extra_codes" ]; then
        echo "  warning: $sh_id ($shell) also produced: $(echo "$extra_codes" | tr '\n' ' ')" >&2
        strict_warnings=$((strict_warnings + 1))
      fi
    fi
  done
  IFS="$old_ifs"

  printf 'verified %s with code %s (%s)\n' "$sh_id" "$expected_code" "$shells_csv"
done <"$mapping_rows"

if "$strict" && [ "$strict_warnings" -gt 0 ]; then
  echo "oracle verification passed with $strict_warnings noisy example(s)" >&2
else
  echo "oracle verification passed"
fi
