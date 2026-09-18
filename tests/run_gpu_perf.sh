#!/bin/sh
#
# Measure a gpu16 kernel's cycle count and check it against the band
# docs/gpu_isa.md section 7.4 predicts for it.
#
# The correctness run comes first and this script stops if it fails.  That
# ordering is the whole point of having a second script: a cycle count is
# meaningless unless the kernel computed the right answer, and a kernel that
# skips half its k panels is *faster*.  The testbench prints the counters
# only as "PERF" lines and compares none of them, so there is no way for a
# performance number to be reported by a run that did not also check its
# result against tests/<kernel>.mexpect.
#
# The band is passed in rather than being read out of the RTL, and both ends
# of it are in the document: section 7.4 carries the tier-1 prediction and its
# tolerance, and section 7.3 carries the measurement this script produced.  A
# change that moves the cycle count outside the band is supposed to fail here
# and be argued about in the document, not quietly re-baselined.
#
# usage:
#   run_gpu_perf.sh <asm-exe> <src-dir> <program.s> <data> <expect> <mexpect>
#                   <mexpect-word> <mexpect-words> <waves> <cycles>
#                   <cycles-low> <cycles-high> <mma-busy>

set -e

if [ "$#" -ne 13 ]; then
    echo "usage: $0 <asm-exe> <src-dir> <program.s> <data> <expect> <mexpect> <mexpect-word> <mexpect-words> <waves> <cycles> <cycles-low> <cycles-high> <mma-busy>" >&2
    exit 2
fi

ASM="$1"
SRC_DIR="$2"
PROGRAM="$3"
DATA="$4"
EXPECT="$5"
MEXPECT="$6"
MWORD="$7"
MWORDS="$8"
WAVES="$9"
CYCLES="${10}"
LOW="${11}"
HIGH="${12}"
MMA_BUSY="${13}"

NAME=$(basename "$PROGRAM" .s)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

count_words() {
    sed 's|//.*||' "$1" | tr -s ' \t' '\n' | grep -c '[0-9a-fA-FxXzZ]' || true
}

echo "=== $NAME: assembling $PROGRAM"
if ! "$ASM" --hex --sep_with_line < "$PROGRAM" > "$WORK_DIR/program.list"; then
    echo "TEST FAIL: $NAME: asm_gpu16 rejected $PROGRAM" >&2
    exit 1
fi

echo "=== $NAME: compiling testgpu.v"
iverilog -Wall -I "$SRC_DIR" -o "$WORK_DIR/sim" "$SRC_DIR/testgpu.v"

echo "=== $NAME: running, and checking the result matrix first"
vvp "$WORK_DIR/sim" \
    "+program=$WORK_DIR/program.list" \
    "+program_words=$(count_words "$WORK_DIR/program.list")" \
    "+data=$DATA" "+data_words=$(count_words "$DATA")" \
    "+expect=$EXPECT" \
    "+mexpect=$MEXPECT" "+mexpect_word=$MWORD" "+mexpect_words=$MWORDS" \
    "+waves=$WAVES" "+cycles=$CYCLES" +perf 2>&1 | tee "$WORK_DIR/sim.log"

if ! grep -q "TEST PASS" "$WORK_DIR/sim.log"; then
    echo "TEST FAIL: $NAME: the kernel's result is wrong, so its cycle count" >&2
    echo "           is not worth reading and is not reported" >&2
    exit 1
fi

RAN=$(sed -n 's/^PERF cycles \([0-9]*\)$/\1/p' "$WORK_DIR/sim.log")
BUSY=$(sed -n 's/^PERF s2 \([0-9]*\)$/\1/p' "$WORK_DIR/sim.log")
INSTRS=$(sed -n 's/^PERF s1 \([0-9]*\)$/\1/p' "$WORK_DIR/sim.log")
BYTES=$(sed -n 's/^PERF s3 \([0-9]*\)$/\1/p' "$WORK_DIR/sim.log")
TRANS=$(sed -n 's/^PERF s4 \([0-9]*\)$/\1/p' "$WORK_DIR/sim.log")

if [ -z "$RAN" ] || [ -z "$BUSY" ]; then
    echo "TEST FAIL: $NAME: the run reported no counters" >&2
    exit 1
fi

echo "--- $NAME: $RAN cycles, $BUSY matrix cycles, $INSTRS instructions per wave"
echo "--- $NAME: $BYTES global bytes in $TRANS transactions"
echo "--- $NAME: matrix utilisation $((BUSY * 1000 / RAN)) per mille"

status=0
if [ "$RAN" -lt "$LOW" ] || [ "$RAN" -gt "$HIGH" ]; then
    echo "TEST FAIL: $NAME: $RAN cycles is outside the band $LOW - $HIGH that" >&2
    echo "           docs/gpu_isa.md section 7.4 predicts" >&2
    status=1
fi
if [ "$BUSY" -ne "$MMA_BUSY" ]; then
    echo "TEST FAIL: $NAME: the matrix unit was busy $BUSY cycles, not the" >&2
    echo "           $MMA_BUSY that section 4.7's sixteen cycles an mma give" >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "TEST PASS: $NAME: $RAN cycles, inside $LOW - $HIGH, and $BUSY matrix cycles"
fi

exit $status
