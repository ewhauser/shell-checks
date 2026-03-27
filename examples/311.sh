#!/bin/bash
# shellcheck disable=2179,2128
exts=("txt" "pdf" "doc")
exts="${exts[*]}"
exts+=" ${exts^^}"
echo "$exts"
