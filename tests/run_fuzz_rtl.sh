#!/bin/sh
#
# Run randomly generated programs on the real verilog.
#
# c16_verify already checks the compiler against a reference interpreter and
# an independent model of the CPU, but all of that runs in C++.  This script
# takes the programs it generated, together with the answers the INTERPRETER
# predicted for them, and puts them through iverilog and cpu16.v.
#
# That closes the loop.  The expectation comes from evaluating the source
# language directly; the answer comes from the actual hardware description.
# Nothing in between wrote the number down, and no human did either, so a
# pass means the compiler, the encoder and the RTL are all consistent with
# what the program means, on programs nobody chose.
#
# usage:
#   run_fuzz_rtl.sh <verify-exe> <c16-exe> <src-dir> <testbench.v> <count> <seed>

set -e

if [ "$#" -ne 6 ]; then
    echo "usage: $0 <verify-exe> <c16-exe> <src-dir> <testbench.v> <count> <seed>" >&2
    exit 2
fi

VERIFY="$1"
C16="$2"
SRC_DIR="$3"
TESTBENCH="$4"
COUNT="$5"
SEED="$6"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== generating $COUNT random programs from seed $SEED"
if ! "$VERIFY" --fuzz "$COUNT" --seed "$SEED" --functions 1 --statements 2 \
        --rtl-out "$WORK_DIR" > "$WORK_DIR/verify.log" 2>&1; then
    echo "TEST FAIL: the C++ level differential check failed before verilog ran" >&2
    cat "$WORK_DIR/verify.log" >&2
    exit 1
fi
tail -2 "$WORK_DIR/verify.log"

echo "=== compiling $TESTBENCH"
iverilog -Wall -I "$SRC_DIR" -o "$WORK_DIR/sim" "$SRC_DIR/$TESTBENCH"

# cpu16 has no defined power on state for its data memory: without a data
# file the verilog memory is all x, while the ISA simulator starts it at
# zero.  That is a difference in the initial state, not a difference in the
# CPU, so the two are put on the same footing by loading an explicitly zero
# memory.  Programs that read a location before writing it would otherwise be
# comparing against something that has no defined value at all.
ZEROS="$WORK_DIR/zeros.data"
: > "$ZEROS"
i=0
while [ "$i" -lt 256 ]; do
    echo "00" >> "$ZEROS"
    i=$((i + 1))
done

RAN=0
for SRC in "$WORK_DIR"/fuzz*.c16; do
    [ -e "$SRC" ] || break
    NAME=$(basename "$SRC" .c16)
    EXPECT="$WORK_DIR/$NAME.expect"

    if ! "$C16" --hex --sep_with_line < "$SRC" > "$WORK_DIR/$NAME.list"; then
        echo "TEST FAIL: $NAME: the compiler rejected a program it had accepted" >&2
        exit 1
    fi

    vvp "$WORK_DIR/sim" \
        "+program=$WORK_DIR/$NAME.list" \
        "+expect=$EXPECT" \
        "+cycles=200000" \
        "+program_words=$(grep -c . "$WORK_DIR/$NAME.list")" \
        "+data=$ZEROS" "+data_words=256" \
        > "$WORK_DIR/$NAME.log" 2>&1

    if grep -q "unknown opcode" "$WORK_DIR/$NAME.log"; then
        echo "TEST FAIL: $NAME: the CPU decoded an unknown opcode" >&2
        cat "$SRC" >&2
        exit 1
    fi
    if ! grep -q "TEST PASS" "$WORK_DIR/$NAME.log"; then
        echo "TEST FAIL: $NAME: cpu16.v did not produce what the language means" >&2
        cat "$WORK_DIR/$NAME.log" >&2
        echo "----- the program -----" >&2
        cat "$SRC" >&2
        exit 1
    fi
    RAN=$((RAN + 1))
done

if [ "$RAN" -eq 0 ]; then
    echo "TEST FAIL: no generated program was actually run on the verilog" >&2
    exit 1
fi

echo "TEST PASS: $RAN random programs ran on cpu16.v and produced exactly what"
echo "           the reference interpreter said the source language means"
exit 0
