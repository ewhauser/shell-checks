#!/bin/bash
# shellcheck disable=2086,2046,2154
find $dir -exec zip -j $OUT/$(basename $dir).zip {} +
