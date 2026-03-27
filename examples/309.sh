#!/bin/bash
# shellcheck disable=2154,2086,2098
CFLAGS="${SLKCFLAGS}" \
CXXFLAGS="${SLKCFLAGS}" \
./configure \
  --target=$ARCH-slackware-linux \
  --with-optmizer=${CFLAGS}
