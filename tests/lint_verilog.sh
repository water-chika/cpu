#!/bin/sh
#
# Compile every verilog source in the repository on its own with
# "iverilog -Wall" and fail if any of them prints a single message.  This is
# what stops a module that nothing instantiates from quietly rotting until it
# no longer compiles at all, which is how cpu8_simd.v and memory_ramb18e1.v
# ended up being deleted rather than repaired.
#
# usage:
#   lint_verilog.sh <src-dir>

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <src-dir>" >&2
    exit 2
fi

SRC_DIR="$1"
status=0

for f in "$SRC_DIR"/*.v; do
    name=$(basename "$f")
    out=$(iverilog -Wall -t null -I "$SRC_DIR" "$f" 2>&1)
    if [ -n "$out" ]; then
        echo "TEST FAIL: $name does not compile cleanly with -Wall:"
        echo "$out"
        status=1
    else
        echo "  ok:       $name"
    fi
done

if [ "$status" -eq 0 ]; then
    echo "TEST PASS: every verilog source compiles with -Wall and says nothing"
fi

exit $status
