#!/bin/bash
# shellcheck disable=1009,1072,1073,1027
if [[ "$x" == (foo|bar)* ]]; then echo ok; fi
