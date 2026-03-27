#!/bin/sh
# shellcheck disable=2154,2086
echo "$MAC" >/dev/null | grep -q 'test' || echo not
