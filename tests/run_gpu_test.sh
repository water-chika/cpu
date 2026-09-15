#!/bin/sh
#
# Run a hand encoded gpu16 scalar program under iverilog and check the final
# scalar registers against an expectation file.  There is no asm32 yet
# (docs/gpu_isa.md section 7.4 lists it as work still to do), so the programs
# are hex words carrying their own disassembly in // comments, which
# $readmemh ignores.
#
# usage:
#   run_gpu_test.sh <src-dir> <program.hex32> <data|-> <expect> <cycles> [plusargs...]

set -e

if [ "$#" -lt 5 ]; then
    echo "usage: $0 <src-dir> <program.hex32> <data|-> <expect> <cycles> [plusargs...]" >&2
    exit 2
fi

SRC_DIR="$1"
PROGRAM="$2"
DATA="$3"
EXPECT="$4"
CYCLES="$5"
shift 5

NAME=$(basename "$PROGRAM" .hex32)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# How many words the file actually holds, once the comments are gone.  The
# testbench passes this to $readmemh so it never warns about a short file.
count_words() {
    sed 's|//.*||' "$1" | tr -s ' \t' '\n' | grep -c '[0-9a-fA-FxXzZ]' || true
}

echo "=== $NAME: compiling testgpu.v"
iverilog -Wall -I "$SRC_DIR" -o "$WORK_DIR/sim" "$SRC_DIR/testgpu.v"

PLUSARGS="+program=$PROGRAM +expect=$EXPECT +cycles=$CYCLES"
PLUSARGS="$PLUSARGS +program_words=$(count_words "$PROGRAM")"
if [ "$DATA" != "-" ]; then
    PLUSARGS="$PLUSARGS +data=$DATA +data_words=$(count_words "$DATA")"
fi

echo "=== $NAME: simulating"
# shellcheck disable=SC2086
vvp "$WORK_DIR/sim" $PLUSARGS "$@" 2>&1 | tee "$WORK_DIR/sim.log"

if grep -q "unknown opcode" "$WORK_DIR/sim.log"; then
    echo "TEST FAIL: $NAME: the wave decoded an unknown opcode" >&2
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
