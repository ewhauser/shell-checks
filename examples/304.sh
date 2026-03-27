#!/bin/sh
# shellcheck disable=1090,1091,3046
myfunc() {
	# shellcheck source=/dev/null
	source "$1"
}
myfunc ./config.sh
