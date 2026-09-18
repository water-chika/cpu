#!/bin/sh
#
# Check that the checked-in matrix-unit expectation files are still exactly
# what tests/gen_mma_expect.py computes from docs/gpu_isa.md section 4.7.
#
# The value of an expectation file is entirely in where it came from.  These
# ones were computed from the ISA document by a Python model of `mma_i8` and
# never read back from the simulator, which is what lets them falsify the RTL
# instead of agreeing with it by construction.  Nothing stops a later session
# from "fixing" a failing test by pasting in what the hardware printed, and
# this is what would notice: the generator is re-run into a scratch directory
# and its output compared byte for byte.
#
# usage:
#   run_gen_check.sh <python> <tests-dir> <generator.py>

set -e

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <python> <tests-dir> <generator.py>" >&2
    exit 2
fi

PYTHON="$1"
TESTS_DIR="$2"
GENERATOR="$3"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== regenerating $GENERATOR's files from the ISA document"
if ! "$PYTHON" "$TESTS_DIR/$GENERATOR" "$WORK_DIR"; then
    echo "TEST FAIL: $GENERATOR did not run" >&2
    exit 1
fi

status=0
for f in "$WORK_DIR"/*; do
    name=$(basename "$f")
    if [ ! -f "$TESTS_DIR/$name" ]; then
        echo "TEST FAIL: $name is generated but not checked in"
        status=1
    elif ! diff -q "$f" "$TESTS_DIR/$name" > /dev/null; then
        echo "TEST FAIL: $name differs from what the ISA document says it is:"
        diff "$TESTS_DIR/$name" "$f" | head -20
        status=1
    else
        echo "  ok:       $name"
    fi
done

if [ "$status" -eq 0 ]; then
    echo "TEST PASS: every file is $GENERATOR's own output"
fi

exit $status
