#!/bin/sh
set -- abc
printf '%s\n' "${1//a/b}"
