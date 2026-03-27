#!/bin/sh
# shellcheck disable=2154,2034,2082,3057,2299
x="${$(svn info):gs/%/%%}"
