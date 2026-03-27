#!/bin/sh
# shellcheck disable=2154,1009,1072,1073,1036
case "$x" in
  foo_(a|b)_*) echo match ;;
esac
