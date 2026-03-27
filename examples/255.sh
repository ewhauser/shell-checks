#!/bin/bash
# shellcheck disable=2038
find . -type d -name CVS | xargs -iX rm -rf "X"
