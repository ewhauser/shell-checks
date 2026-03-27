#!/bin/sh
if [ "lsmod | grep v4l2loopback" ]; then echo loaded; fi
