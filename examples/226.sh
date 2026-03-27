#!/bin/sh
# shellcheck disable=2113,2120,2126,2119
function hgic() {
  hg incoming "$@" | grep changeset | wc -l
}
hgic
