#!/bin/bash
# shellcheck disable=2154,2086
find $PKG -name perllocal.pod -o -name ".packlist" -exec rm -f {} \;
