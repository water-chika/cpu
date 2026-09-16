#!/bin/sh
#
# The branch range of cpu_16_16_16_16, at its four edges.
#
# docs/cpu_16_16_16_16.md section 6 says a conditional branch carries a
# signed 8 bit word displacement from PC_next and a jmp/call carries a signed
# 12 bit one.  A range check is only worth anything if it is exact, so this
# assembles the furthest program that must work and the nearest one that must
# not, in both directions, for both formats.
#
# The programs are generated rather than checked in because one of them is
# 2050 lines of nop.
#
# usage:
#   run_cpu_16_16_16_16_range.sh <asm-exe>

set -e

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <asm-exe>" >&2
    exit 2
fi

ASM="$1"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
FAILED=0

# nops "$count" > file
nops() {
    i=0
    while [ "$i" -lt "$1" ]; do
        echo "nop"
        i=$((i + 1))
    done
}

# forward <op> <padding> -> a program whose branch displacement is <padding>
forward() {
    echo "$1 target"
    nops "$2"
    echo "target:"
    echo "halt"
}

# backward <op> <padding> -> displacement -(padding + 1)
backward() {
    echo "target:"
    nops "$2"
    echo "$1 target"
    echo "halt"
}

# check <name> <accept|reject> <program-file>
check() {
    if "$ASM" --hex < "$3" > "$WORK_DIR/out" 2> "$WORK_DIR/err"; then
        if [ "$2" = "accept" ]; then
            echo "ok: $1"
        else
            echo "TEST FAIL: $1: assembled, and it is out of range" >&2
            FAILED=1
        fi
        return 0
    fi
    if [ "$2" = "reject" ]; then
        if grep -qF -- "is too far away for this branch" "$WORK_DIR/err"; then
            echo "ok: $1"
        else
            echo "TEST FAIL: $1: rejected, but not for being out of range" >&2
            echo "  got: $(cat "$WORK_DIR/err")" >&2
            FAILED=1
        fi
    else
        echo "TEST FAIL: $1: rejected, and it is in range" >&2
        echo "  got: $(cat "$WORK_DIR/err")" >&2
        FAILED=1
    fi
}

# A conditional branch: -128 to +127 words.
forward  beq 127  > "$WORK_DIR/p"; check "beq +127"  accept "$WORK_DIR/p"
forward  beq 128  > "$WORK_DIR/p"; check "beq +128"  reject "$WORK_DIR/p"
backward beq 127  > "$WORK_DIR/p"; check "beq -128"  accept "$WORK_DIR/p"
backward beq 128  > "$WORK_DIR/p"; check "beq -129"  reject "$WORK_DIR/p"

# br is the same format, so it has the same range.
forward  br  127  > "$WORK_DIR/p"; check "br +127"   accept "$WORK_DIR/p"
forward  br  128  > "$WORK_DIR/p"; check "br +128"   reject "$WORK_DIR/p"

# jmp and call: -2048 to +2047 words.
forward  jmp 2047 > "$WORK_DIR/p"; check "jmp +2047" accept "$WORK_DIR/p"
forward  jmp 2048 > "$WORK_DIR/p"; check "jmp +2048" reject "$WORK_DIR/p"
backward jmp 2047 > "$WORK_DIR/p"; check "jmp -2048" accept "$WORK_DIR/p"
backward jmp 2048 > "$WORK_DIR/p"; check "jmp -2049" reject "$WORK_DIR/p"
forward  call 2047 > "$WORK_DIR/p"; check "call +2047" accept "$WORK_DIR/p"
forward  call 2048 > "$WORK_DIR/p"; check "call +2048" reject "$WORK_DIR/p"

if [ "$FAILED" -eq 0 ]; then
    echo "=== branch range: all twelve edges as documented"
fi
exit $FAILED
