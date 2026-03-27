#!/bin/bash
# shellcheck disable=2086,2154,2038
find $PKG | xargs file | egrep "ELF.*executable" | cut -f 1 -d :
