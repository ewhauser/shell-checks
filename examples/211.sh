#!/bin/bash
# shellcheck disable=2154
if ! grep ^"$user": /etc/passwd 2>&1 > /dev/null; then echo missing; fi
