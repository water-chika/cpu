#!/bin/sh
#
# Cross check the independent ISA simulator against the actual verilog.
#
# Every other test in this repository compares the hardware against a number
# a human wrote down.  That proves the stack agrees with the author, and if
# the author's arithmetic was wrong it proves nothing at all.  This script
# removes the human from the loop: cpu16_sim executes the program, and its
# prediction for ALL EIGHT registers becomes the expectation that cpu16.v
# then has to meet.
#
# Two independent implementations of the same ISA, written from the same
# specification but sharing no code, agreeing on the final state of every
# register: that is a real check.  A disagreement indicts one of exactly two
# things, the simulator's reading of the ISA or the RTL's, and nothing else
# is in the picture, because the program and its input are identical.
#
# The program can be given either as cpu16 assembly or as a c16 source file;
# the extension decides which tool turns it into machine words.
#
# usage:
#   run_cross_check.sh <asm-exe> <c16-exe> <sim-exe> <src-dir> <testbench.v> \
#                      <program.s|program.c16> <data|-> <cycles>

set -e

if [ "$#" -ne 8 ]; then
    echo "usage: $0 <asm-exe> <c16-exe> <sim-exe> <src-dir> <testbench.v> <program> <data|-> <cycles>" >&2
    exit 2
fi

ASM="$1"
C16="$2"
SIM="$3"
SRC_DIR="$4"
TESTBENCH="$5"
PROGRAM="$6"
DATA="$7"
CYCLES="$8"

NAME=$(basename "$PROGRAM")
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

case "$PROGRAM" in
    *.c16)
        echo "=== $NAME: compiling"
        if ! "$C16" --hex --sep_with_line < "$PROGRAM" > "$WORK_DIR/program.list"; then
            echo "TEST FAIL: $NAME: the compiler rejected it" >&2
            exit 1
        fi
        ;;
    *)
        echo "=== $NAME: assembling"
        if ! "$ASM" --hex --sep_with_line < "$PROGRAM" > "$WORK_DIR/program.list"; then
            echo "TEST FAIL: $NAME: the assembler rejected it" >&2
            exit 1
        fi
        ;;
esac

SIM_ARGS="--cycles $CYCLES"
if [ "$DATA" != "-" ]; then
    SIM_ARGS="$SIM_ARGS --data $DATA"
fi

echo "=== $NAME: predicting the final registers with the ISA simulator"
# shellcheck disable=SC2086
if ! "$SIM" $SIM_ARGS "$WORK_DIR/program.list" > "$WORK_DIR/predicted.expect"; then
    echo "TEST FAIL: $NAME: the ISA simulator could not run the program" >&2
    cat "$WORK_DIR/predicted.expect" >&2
    exit 1
fi
if [ "$(grep -c . "$WORK_DIR/predicted.expect")" -ne 8 ]; then
    echo "TEST FAIL: $NAME: the simulator did not predict all eight registers" >&2
    cat "$WORK_DIR/predicted.expect" >&2
    exit 1
fi
echo "--- predicted r0..r7:" $(tr '\n' ' ' < "$WORK_DIR/predicted.expect")

echo "=== $NAME: compiling $TESTBENCH"
iverilog -Wall -I "$SRC_DIR" -o "$WORK_DIR/sim" "$SRC_DIR/$TESTBENCH"

PLUSARGS="+program=$WORK_DIR/program.list +expect=$WORK_DIR/predicted.expect"
PLUSARGS="$PLUSARGS +cycles=$CYCLES"
PLUSARGS="$PLUSARGS +program_words=$(grep -c . "$WORK_DIR/program.list")"
if [ "$DATA" != "-" ]; then
    PLUSARGS="$PLUSARGS +data=$DATA +data_words=$(grep -c . "$DATA")"
fi

echo "=== $NAME: running the same program on the real verilog"
# shellcheck disable=SC2086
vvp "$WORK_DIR/sim" $PLUSARGS 2>&1 | tee "$WORK_DIR/sim.log"

if grep -q "unknown opcode" "$WORK_DIR/sim.log"; then
    echo "TEST FAIL: $NAME: the CPU decoded an unknown opcode" >&2
    exit 1
fi
if grep -q "MISMATCH" "$WORK_DIR/sim.log"; then
    echo "TEST FAIL: $NAME: the ISA simulator and cpu16.v disagree about the" >&2
    echo "           final register state, so one of the two is wrong" >&2
    exit 1
fi
if ! grep -q "TEST PASS" "$WORK_DIR/sim.log"; then
    echo "TEST FAIL: $NAME: the simulation never reported a result" >&2
    exit 1
fi

echo "TEST PASS: $NAME: the ISA simulator and cpu16.v agree on all 8 registers"
exit 0
