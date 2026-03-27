#!/bin/sh
# shellcheck disable=2154
echo test |& grep -q foo
