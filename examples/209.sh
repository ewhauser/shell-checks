#!/bin/bash
# shellcheck disable=2044,2035
for f in $(find ./ -name *.jar); do echo "$f"; done
