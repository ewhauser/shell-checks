#!/bin/sh
# shellcheck disable=2154,2086
/sbin/ip link show dev ${iface} 2>&1 | fgrep -q -e"state DOWN" && exit 1
