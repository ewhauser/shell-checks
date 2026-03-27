#!/bin/bash
# shellcheck disable=2086
RUNTIME=$(echo $CLASSPATH | sed 's|foo|bar|g')
echo "$RUNTIME"
