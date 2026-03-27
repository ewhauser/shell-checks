#!/bin/bash
# shellcheck disable=2034
declare -A parts
parts[1]=foo
unset parts["1"]
