#!/bin/bash
# shellcheck disable=2004
start=40
tool=hello
spaces=$(($start - $( echo "$tool" | wc -c)))
echo "$spaces"
