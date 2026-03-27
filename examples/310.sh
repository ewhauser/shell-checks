#!/bin/bash
# shellcheck disable=2154,2086,2097
CFLAGS="${SLKCFLAGS}" \
./configure \
  --with-optmizer=${CFLAGS}
