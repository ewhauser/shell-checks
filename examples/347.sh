#!/bin/sh
# shellcheck disable=2030
n=0
printf '%s
' x | while read -r _; do n=1; done
echo "$n"
