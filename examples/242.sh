#!/bin/sh
# shellcheck disable=2154
cmd "$arg"
if [ $? -ne 0 ]; then echo fail; fi
