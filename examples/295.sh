#!/bin/bash
# shellcheck disable=2164
build() {
    cd mehtadata
    make
    cd ..
    cmake .
}
build
