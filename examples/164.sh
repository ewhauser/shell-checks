#!/bin/bash
a=1
b=jpg
if [ -z "$a" ] && ( [ "$b" = jpeg ] || [ "$b" = jpg ] ); then echo ok; fi
