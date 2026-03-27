#!/bin/bash
# shellcheck disable=2154
echo "$text" | grep -v "start*" > out.txt
