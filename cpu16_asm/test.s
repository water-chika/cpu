# Count r1 up to 4, then halt.
#
# A minimal program that exercises the branch path without touching data
# memory.  Encoding: "imm <value> <shift> <dst>" loads (value << shift), and
# "bnz <cond> <target> 0" branches to the address held in <target> when
# <cond> is not zero.
#
# Register use:
#   r1  counter
#   r2  counter - limit
#   r4  constant 1
#   r5  address of the halt branch (7)
#   r6  address of the loop body (4)
#   r7  limit (4)

imm 4 0 r7
imm 1 0 r4
imm 4 0 r6
imm 7 0 r5

# loop body, address 4
add r1 r4 r1
sub r1 r7 r2
bnz r2 r6 0

# halt: branch to itself forever, address 7
b 0 r5 0
