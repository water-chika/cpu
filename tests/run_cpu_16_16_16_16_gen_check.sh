#!/bin/sh
#
# Check that tests/cpu_16_16_16_16_encoding.expect16 is still exactly what
# tests/gen_cpu_16_16_16_16_encoding.py computes from
# docs/cpu_16_16_16_16.md.
#
# Same argument as run_gen_check.sh: the value of an expectation file is
# entirely in where it came from.  This one was computed from the document by
# a second, independent encoder and never read back from asm_16_16_16_16,
# which is what lets it falsify the assembler instead of agreeing with it by
# construction.  Nothing stops a later session from "fixing" a failing
# encoding test by pasting in what the assembler printed, and this is what
# would notice.
#
# usage:
#   run_cpu_16_16_16_16_gen_check.sh <python> <tests-dir>

set -e

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <python> <tests-dir>" >&2
    exit 2
fi

PYTHON="$1"
TESTS_DIR="$2"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== regenerating the cpu_16_16_16_16 encoding expectation from the document"
if ! "$PYTHON" "$TESTS_DIR/gen_cpu_16_16_16_16_encoding.py" \
        < "$TESTS_DIR/cpu_16_16_16_16_encoding.s" > "$WORK_DIR/expect16"; then
    echo "TEST FAIL: gen_cpu_16_16_16_16_encoding.py did not run" >&2
    exit 1
fi

if ! diff -u "$TESTS_DIR/cpu_16_16_16_16_encoding.expect16" "$WORK_DIR/expect16"; then
    echo "TEST FAIL: the checked-in expectation is not what the document says" >&2
    exit 1
fi

echo "TEST PASS: the encoding expectation is the generator's output, $(grep -c . "$WORK_DIR/expect16") words"
exit 0
