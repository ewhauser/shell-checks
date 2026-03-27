#!/bin/sh
# shellcheck disable=2154
echo "${*%%dBm*}" > /tmp/signal.txt
