#!/bin/sh
exec {fd}>/dev/null
printf '%s\n' "$fd"
