#!/bin/sh
#
# Assemble a cpu_16_16_16_16 program with asm_16_16_16_16, run it under
# iverilog and check the final registers - and, optionally, data memory -
# against expectation files.
#
# Same shape as run_gpu_test.sh, including the trailing plusargs, which is
# what carries +mexpect: a store test that only reads its own stores back
# cannot see a load and a store that are wrong in the same direction, so the
# store tests compare the memory array itself against words computed from
# docs/cpu_16_16_16_16.md.
#
# usage:
#   run_test_16_16_16_16.sh <asm-exe> <src-dir> <program.s> <data|-> <expect> <cycles> [plusargs...]

set -e

if [ "$#" -lt 6 ]; then
    echo "usage: $0 <asm-exe> <src-dir> <program.s> <data|-> <expect> <cycles> [plusargs...]" >&2
    exit 2
fi

ASM="$1"
SRC_DIR="$2"
PROGRAM="$3"
DATA="$4"
EXPECT="$5"
CYCLES="$6"
shift 6

NAME=$(basename "$PROGRAM" .s)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# How many words the file actually holds, once the comments are gone.  The
# testbench passes this to $readmemh so it never warns about a short file.
count_words() {
    sed 's|//.*||' "$1" | tr -s ' \t' '\n' | grep -c '[0-9a-fA-FxXzZ]' || true
}

echo "=== $NAME: assembling $PROGRAM"
if ! "$ASM" --hex --sep_with_line < "$PROGRAM" > "$WORK_DIR/program.list"; then
    echo "TEST FAIL: $NAME: asm_16_16_16_16 rejected $PROGRAM" >&2
    exit 1
fi
if [ ! -s "$WORK_DIR/program.list" ]; then
    echo "TEST FAIL: $NAME: asm_16_16_16_16 produced an empty program" >&2
    exit 1
fi

echo "=== $NAME: compiling test_16_16_16_16.v"
iverilog -Wall -I "$SRC_DIR" -o "$WORK_DIR/sim" "$SRC_DIR/test_16_16_16_16.v"

PLUSARGS="+program=$WORK_DIR/program.list +expect=$EXPECT +cycles=$CYCLES"
PLUSARGS="$PLUSARGS +program_words=$(count_words "$WORK_DIR/program.list")"
if [ "$DATA" != "-" ]; then
    PLUSARGS="$PLUSARGS +data=$DATA +data_words=$(count_words "$DATA")"
fi

echo "=== $NAME: simulating"
# shellcheck disable=SC2086
vvp "$WORK_DIR/sim" $PLUSARGS "$@" 2>&1 | tee "$WORK_DIR/sim.log"

if grep -q "unknown opcode" "$WORK_DIR/sim.log"; then
    echo "TEST FAIL: $NAME: the core decoded an unknown opcode" >&2
    exit 1
fi
if grep -q "WARNING" "$WORK_DIR/sim.log"; then
    echo "TEST FAIL: $NAME: the simulation printed a warning" >&2
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
