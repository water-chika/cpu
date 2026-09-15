#!/bin/sh
#
# Assemble a program, simulate it with iverilog and check the final register
# values against an expectation file.  Exits non zero (loudly) if the program
# fails to assemble, the simulation hits an unknown opcode, or any register
# ends up holding something other than what the .expect file says.
#
# usage:
#   run_test.sh <asm-exe> <src-dir> <testbench.v> <program.s> <data|-> <expect> <cycles>

set -e

if [ "$#" -ne 7 ]; then
    echo "usage: $0 <asm-exe> <src-dir> <testbench.v> <program.s> <data|-> <expect> <cycles>" >&2
    exit 2
fi

ASM="$1"
SRC_DIR="$2"
TESTBENCH="$3"
PROGRAM="$4"
DATA="$5"
EXPECT="$6"
CYCLES="$7"

NAME=$(basename "$PROGRAM" .s)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== $NAME: assembling $PROGRAM"
if ! "$ASM" --hex --sep_with_line < "$PROGRAM" > "$WORK_DIR/program.list"; then
    echo "TEST FAIL: $NAME: assembler rejected $PROGRAM" >&2
    exit 1
fi
if [ ! -s "$WORK_DIR/program.list" ]; then
    echo "TEST FAIL: $NAME: assembler produced an empty program" >&2
    exit 1
fi

echo "=== $NAME: compiling $TESTBENCH"
iverilog -Wall -I "$SRC_DIR" -o "$WORK_DIR/sim" "$SRC_DIR/$TESTBENCH"

PLUSARGS="+program=$WORK_DIR/program.list +expect=$EXPECT +cycles=$CYCLES"
PLUSARGS="$PLUSARGS +program_words=$(grep -c . "$WORK_DIR/program.list")"
if [ "$DATA" != "-" ]; then
    PLUSARGS="$PLUSARGS +data=$DATA +data_words=$(grep -c . "$DATA")"
fi

echo "=== $NAME: simulating"
# shellcheck disable=SC2086
vvp "$WORK_DIR/sim" $PLUSARGS 2>&1 | tee "$WORK_DIR/sim.log"

if grep -q "unknown opcode" "$WORK_DIR/sim.log"; then
    echo "TEST FAIL: $NAME: the CPU decoded an unknown opcode, the program ran off its end" >&2
    exit 1
fi
if grep -q "TEST FAIL" "$WORK_DIR/sim.log"; then
    exit 1
fi
if ! grep -q "TEST PASS" "$WORK_DIR/sim.log"; then
    echo "TEST FAIL: $NAME: the simulation never reported a result" >&2
    exit 1
fi

exit 0
