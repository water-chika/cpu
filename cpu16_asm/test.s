# Count r1 up to 4, then halt.
#
# A minimal program that exercises the branch path without touching data
# memory.  Encoding: "imm <value> <shift> <dst>" loads (value << shift), and
# "bnz <cond> <target> 0" branches to the address held in <target> when
# <cond> is not zero.  "la <dst> <label>" puts a label's address into a
# register, so no address has to be built by hand any more.
#
# Register use:
#   r1  counter
#   r2  counter - limit
#   r4  constant 1
#   r5  address of the halt branch
#   r6  address of the loop body
#   r7  limit (4)

imm 4 0 r7
imm 1 0 r4
la r6 loop
la r5 halt

loop:
add r1 r4 r1
sub r1 r7 r2
bnz r2 r6 0

# halt: branch to itself forever
halt:
b 0 r5 0
