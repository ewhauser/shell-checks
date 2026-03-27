#!/bin/sh
# shellcheck disable=2006,2046
git branch -d `git branch --merged | grep -v '^*' | grep -v 'master' | tr -d '
'`
