#!/bin/sh
#
# Check that the assembler rejects the programs it is supposed to reject.
#
# Each case is one line of source and the text the diagnostic has to contain.
# Accepting nonsense silently is the failure mode that matters for an
# assembler whose output nobody can read, so the refusals are tested as
# deliberately as the encodings are.
#
# usage:
#   run_reject_test.sh <asm-exe> <cases-file>
#
# The cases file holds "source text <TAB> expected diagnostic substring" per
# line; blank lines and # comments are ignored.

set -e

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <asm-exe> <cases-file>" >&2
    exit 2
fi

ASM="$1"
CASES="$2"
FAILED=0

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

while IFS='	' read -r source want; do
    case "$source" in ''|'#'*) continue ;; esac

    printf '%s\n' "$source" > "$WORK_DIR/case.s"
    if "$ASM" --hex < "$WORK_DIR/case.s" > "$WORK_DIR/out" 2> "$WORK_DIR/err"; then
        echo "TEST FAIL: assembled \"$source\", which is not legal gpu16" >&2
        FAILED=1
        continue
    fi
    if ! grep -qF -- "$want" "$WORK_DIR/err"; then
        echo "TEST FAIL: \"$source\" was rejected, but not for the stated reason" >&2
        echo "  wanted a diagnostic containing: $want" >&2
        echo "  got: $(cat "$WORK_DIR/err")" >&2
        FAILED=1
        continue
    fi
    echo "ok: $source"
done < "$CASES"

exit $FAILED
