#!/bin/bash
# shellcheck disable=1078,2068,2145,2027
echo "#!/bin/bash
if [[ "$@" =~ x ]]; then :; fi
"
