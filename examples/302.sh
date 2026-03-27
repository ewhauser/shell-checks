#!/bin/bash
backend="x11-sdl"
case "$backend" in
    x11*)
        params="-fullscreen"
        ;;
    default|x11*)
        params="-windowed"
        ;;
esac
echo "$params"
