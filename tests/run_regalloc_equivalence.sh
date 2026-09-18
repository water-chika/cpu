#!/bin/sh
#
# Check that keeping variables in registers does not change what a program
# computes.
#
# The register allocator described in docs/c16.md, "Variables in registers",
# is an optimisation, and the only thing an optimisation is allowed to do is
# make the program smaller or faster.  The way to prove it did nothing else
# is to keep the unoptimised compiler around and compare: --no-regalloc
# leaves every variable in its frame byte, which is the code the compiler
# emitted before this stage existed and which the whole test suite already
# trusts.
#
# So this script compiles the same source twice, once each way, runs both
# through the ISA simulator, and demands that the registers the program
# reports its answers in end up holding the same values.  It compares those
# and no others: a register the allocator handed to a variable still holds
# whatever that variable was left at when the program halted, and a
# difference up there is the stage working, not the stage lying.  A variable given a register it was not entitled
# to - one whose live range really did overlap another's - shows up here as a
# wrong answer rather than as nothing at all.  It also demands that the
# allocated program is no longer than the unallocated one, because a stage
# that costs words while claiming to save them is a bug too.
#
# usage:
#   run_regalloc_equivalence.sh <c16-exe> <sim-exe> <program.c16> <cycles> \
#                               <out-slots>
#
# <out-slots> is how many out() slots the program writes, which is how many
# of r0..r6 carry an answer; c16_verify prints the mask if it is not obvious.

set -e

if [ "$#" -ne 5 ]; then
    echo "usage: $0 <c16-exe> <sim-exe> <program.c16> <cycles> <out-slots>" >&2
    exit 2
fi

C16="$1"
SIM="$2"
PROGRAM="$3"
CYCLES="$4"
OUTS="$5"

NAME=$(basename "$PROGRAM")
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== $NAME: compiling with every variable in memory"
if ! "$C16" --no-regalloc --hex --sep_with_line < "$PROGRAM" > "$WORK_DIR/before.list"; then
    echo "TEST FAIL: $NAME: the compiler rejected it with --no-regalloc" >&2
    exit 1
fi

echo "=== $NAME: compiling with variables in registers"
if ! "$C16" --hex --sep_with_line < "$PROGRAM" > "$WORK_DIR/after.list"; then
    echo "TEST FAIL: $NAME: the compiler rejected it" >&2
    exit 1
fi

BEFORE_WORDS=$(grep -c . "$WORK_DIR/before.list")
AFTER_WORDS=$(grep -c . "$WORK_DIR/after.list")
echo "--- $BEFORE_WORDS words in memory, $AFTER_WORDS words with registers"

if [ "$AFTER_WORDS" -gt "$BEFORE_WORDS" ]; then
    echo "TEST FAIL: $NAME: allocating registers made the program longer," >&2
    echo "           $BEFORE_WORDS words became $AFTER_WORDS" >&2
    exit 1
fi

for WHICH in before after; do
    if ! "$SIM" --cycles "$CYCLES" "$WORK_DIR/$WHICH.list" > "$WORK_DIR/$WHICH.regs"; then
        echo "TEST FAIL: $NAME: the ISA simulator could not run the $WHICH program" >&2
        cat "$WORK_DIR/$WHICH.regs" >&2
        exit 1
    fi
    if [ "$(grep -c . "$WORK_DIR/$WHICH.regs")" -ne 8 ]; then
        echo "TEST FAIL: $NAME: the $WHICH run did not report all eight registers" >&2
        exit 1
    fi
    head -n "$OUTS" "$WORK_DIR/$WHICH.regs" > "$WORK_DIR/$WHICH.outs"
done

echo "--- in memory    out 0..$((OUTS - 1)):" $(tr '\n' ' ' < "$WORK_DIR/before.outs")
echo "--- in registers out 0..$((OUTS - 1)):" $(tr '\n' ' ' < "$WORK_DIR/after.outs")

if ! diff "$WORK_DIR/before.outs" "$WORK_DIR/after.outs" > "$WORK_DIR/diff"; then
    echo "TEST FAIL: $NAME: the allocated program computes something else," >&2
    echo "           so a variable was given a register it may not have:" >&2
    cat "$WORK_DIR/diff" >&2
    exit 1
fi

echo "TEST PASS: $NAME: the same result with variables in memory and in registers"
exit 0
