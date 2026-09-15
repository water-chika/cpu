#!/bin/sh
#
# Compile a c16 program down both of the compiler's output paths, check that
# the two agree byte for byte, then simulate the result with iverilog and
# check the final register values against an expectation file.
#
# The two paths are:
#
#   text    c16 --asm writes cpu16 assembly, and this repository's own asm16
#           assembles it, unmodified, into machine words.
#   binary  c16 --hex lowers straight to machine words, without ever
#           formatting or re-lexing any text.
#
# They are meant to be indistinguishable in their output, so this script
# diffs them and fails loudly if they are not.  What is simulated afterwards
# is the binary path, because that is the one the benchmark measures.
#
# Exits non zero (loudly) if the program fails to compile, the paths
# disagree, the assembler rejects the compiler's own assembly, the simulation
# hits an unknown opcode, or any register ends up holding something other
# than what the .expect file says.
#
# usage:
#   run_c16_test.sh <c16-exe> <asm-exe> <src-dir> <testbench.v> <program.c16> <data|-> <expect> <cycles>

set -e

if [ "$#" -ne 8 ]; then
    echo "usage: $0 <c16-exe> <asm-exe> <src-dir> <testbench.v> <program.c16> <data|-> <expect> <cycles>" >&2
    exit 2
fi

C16="$1"
ASM="$2"
SRC_DIR="$3"
TESTBENCH="$4"
PROGRAM="$5"
DATA="$6"
EXPECT="$7"
CYCLES="$8"

NAME=$(basename "$PROGRAM" .c16)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== $NAME: compiling $PROGRAM down the binary path"
if ! "$C16" --hex --sep_with_line < "$PROGRAM" > "$WORK_DIR/program.list"; then
    echo "TEST FAIL: $NAME: the compiler rejected $PROGRAM" >&2
    exit 1
fi
if [ ! -s "$WORK_DIR/program.list" ]; then
    echo "TEST FAIL: $NAME: the compiler produced an empty program" >&2
    exit 1
fi

echo "=== $NAME: compiling $PROGRAM down the text path"
if ! "$C16" --asm < "$PROGRAM" > "$WORK_DIR/program.s"; then
    echo "TEST FAIL: $NAME: the compiler rejected $PROGRAM on its text path" >&2
    exit 1
fi
if ! "$ASM" --hex --sep_with_line < "$WORK_DIR/program.s" > "$WORK_DIR/viatext.list"; then
    echo "TEST FAIL: $NAME: asm16 rejected the assembly the compiler emitted" >&2
    exit 1
fi

echo "=== $NAME: checking the two paths agree"
if ! diff -u "$WORK_DIR/viatext.list" "$WORK_DIR/program.list" > "$WORK_DIR/paths.diff"; then
    echo "TEST FAIL: $NAME: the text and binary paths produced different machine words" >&2
    head -40 "$WORK_DIR/paths.diff" >&2
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
