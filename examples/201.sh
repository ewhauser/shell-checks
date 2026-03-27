#!/bin/bash
# shellcheck disable=2086
[ $DIR = vendor ] && mv go-* $DIR || mv pkg-* $DIR
