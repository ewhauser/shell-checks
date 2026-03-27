#!/bin/sh
trap '
    echo caught signal, cleaning up...
    exit 1
  ' 1 2 13 15
