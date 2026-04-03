#!/bin/sh
foo() { echo hello; }
find . -exec foo {} \;
