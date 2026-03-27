#!/bin/sh
x=foo
[ "$x" = foo ] && [ "$x" = bar ] || [ "$x" = baz ]
