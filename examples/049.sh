#!/bin/sh
for f in $(find . -name '*.txt'); do printf '%s\n' "$f"; done
