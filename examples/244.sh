#!/bin/bash
# shellcheck disable=2034
mapfile -t files < <(find -name "*.pyc" -printf '%f
')
