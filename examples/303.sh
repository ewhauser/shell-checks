#!/bin/sh
# shellcheck disable=2034,2082,2299,2154,3057
if is-at-least 3.1 ${"$(rsync --version 2>&1)"[(w)3]}; then
  echo new
fi
