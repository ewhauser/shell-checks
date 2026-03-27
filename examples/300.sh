#!/bin/bash
# shellcheck disable=2213
while getopts "hb:c:" opt; do
    case "$opt" in
    h)
        echo help
        exit 0
        ;;
    b)
        bg="$OPTARG"
        ;;
    esac
done
echo "${bg:-}"
