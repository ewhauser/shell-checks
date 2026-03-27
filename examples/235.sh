#!/bin/sh
# shellcheck disable=2034
alias gtl='gtl(){ git tag --sort=-v:refname -n -l "${1}*" }; noglob gtl'
