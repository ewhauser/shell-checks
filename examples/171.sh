#!/bin/sh
myfunc() { return 1; }
myfunc() { return 0; }
myfunc
