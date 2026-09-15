# Check ld_p and st_p, the two instructions that reach program memory.
#
# The program rewrites one of its own instructions and then runs it.  The
# instruction at "patch" is assembled as "imm 0 0 r7" (0x1807); both of its
# bytes are overwritten so that it becomes "imm 7 0 r7" (0x19c7), and r7 ends
# up holding 7 rather than 0.  Both halves are then read back with ld_p, which
# is how the store is checked independently of the fetch.
#
# Field reminder:
#   st_p <src0> <address register> <half>
#   ld_p <half> <address register> <dst>
# where half is 0 for the low byte of the word and 1 for the high byte.
#
# Register use:
#   r0  address of the instruction being patched
#   r1  0x19, its new high byte
#   r2  0xc7, its new low byte
#   r3  high byte read back, r4 low byte read back
#   r5  address of the halt branch
#   r7  0 unless the patched instruction really ran

la r0 patch

imm 3 3 r1
imm_s 1 0 r1
st_p r1 r0 1

imm 3 6 r2
imm_s 7 0 r2
st_p r2 r0 0

ld_p 1 r0 r3
ld_p 0 r0 r4

la r5 halt

patch:
imm 0 0 r7

halt:
b 0 r5 0
