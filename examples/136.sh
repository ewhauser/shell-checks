#!/bin/sh
ssh server << EOF
echo $1
EOF
