#!/bin/sh
a=b
var=a
printf '%s\n' "$a" "${!var}"
