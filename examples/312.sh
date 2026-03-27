#!/bin/sh
# shellcheck disable=2034,2154,2214,2220
while getopts ':a:d:o:h' OPT; do
	case "$OPT" in
		a) alg=$OPTARG;;
		d) domain=$OPTARG;;
		h) echo help; exit 0;;
	esac
done
