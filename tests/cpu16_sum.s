# Sum the first 8 bytes of data memory into r2.
#
# The data file holds 1..8, so the expected result is 36 (0x24).
#
# Register use:
#   r0  index into data memory
#   r1  limit (8)
#   r2  accumulator
#   r3  loaded value
#   r4  constant 1
#   r5  index - limit
#   r6  address of the loop body (7)
#   r7  address of the halt branch (12)
#
# Encoding reminder: "imm <value> <shift> <dst>" loads (value << shift) and
# "imm_s <value> <shift> <dst>" ors (value << shift) into an existing
# register, so the two together build any 8 bit constant.

imm 0 0 r0
imm 0 0 r2
imm 1 0 r4
imm 1 3 r1
imm 7 0 r6
imm 1 3 r7
imm_s 4 0 r7

# loop body, address 7
ld 0 r0 r3
add r2 r3 r2
add r0 r4 r0
sub r0 r1 r5
bnz r5 r6 0

# halt: branch to itself forever, address 12
b 0 r7 0
