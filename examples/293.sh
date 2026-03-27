#!/bin/bash
if [ -f /etc/hosts ]; then
  echo found
  exit 0
else
  echo missing
  exit 1
fi
echo unreachable
