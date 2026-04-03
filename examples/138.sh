#!/bin/sh
while read line; do
  ssh host echo test
done
