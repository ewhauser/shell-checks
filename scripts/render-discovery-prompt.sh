#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
template_path="$root_dir/discovery/prompt-template.md"

cat "$template_path"
