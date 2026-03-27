#!/bin/sh
# shellcheck disable=2086,2154,2044
for file in $( find 2>/dev/null "$dir" -type f -name '[0-9]*' ); do echo "$file"; done
