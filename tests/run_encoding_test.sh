#!/bin/sh
#
# Assemble a program and compare the words it produces against a checked in
# expectation, one hex word per line.
#
# This is how the instructions no core can execute yet are held down.  A
# simulation test needs hardware; an encoding test only needs the document,
# so the vector ALU, the matrix unit, LDS and the exec mask are all pinned
# here even though gpu16.v is scalar only.
#
# usage:
#   run_encoding_test.sh <asm-exe> <program.s> <expect-words>

set -e

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <asm-exe> <program.s> <expect-words>" >&2
    exit 2
fi

ASM="$1"
PROGRAM="$2"
EXPECT="$3"

NAME=$(basename "$PROGRAM" .s)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== $NAME: assembling $PROGRAM"
if ! "$ASM" --hex --sep_with_line < "$PROGRAM" > "$WORK_DIR/got"; then
    echo "TEST FAIL: $NAME: the assembler rejected $PROGRAM" >&2
    exit 1
fi

if ! diff -u "$EXPECT" "$WORK_DIR/got" > "$WORK_DIR/diff"; then
    echo "TEST FAIL: $NAME: the encoding changed" >&2
    echo "  - is what $(basename "$EXPECT") says, + is what the assembler produced" >&2
    cat "$WORK_DIR/diff" >&2
    exit 1
fi

echo "=== $NAME: $(grep -c . "$EXPECT") words, all as expected"
exit 0
