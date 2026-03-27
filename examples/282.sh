#!/bin/sh
# shellcheck disable=2154,2166
if [ ! -O "$file" -a -w "$file" ]; then echo writable; fi
