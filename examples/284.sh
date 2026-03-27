#!/bin/bash
# shellcheck disable=2154,2160
arr=(a b c d)
if [[ true ]] && $(( ${#arr[@]}%2 )) -eq 0 ]]; then echo even; fi
