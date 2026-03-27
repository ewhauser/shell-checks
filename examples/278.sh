#!/bin/sh
# shellcheck disable=2154,3053
for i in ${!ARRAY[*]}; do echo "$i"; done
