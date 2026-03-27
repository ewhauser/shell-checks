#!/bin/sh
# shellcheck disable=2034,2154,2220,2213
while getopts ':a:d:h' OPT; do
	case "$OPT" in
		a) alg=$OPTARG;;
		d) domain=$OPTARG;;
		k) keyfile=$OPTARG;;
		h) echo help; exit 0;;
	esac
done
