# Sum the first 8 bytes of data memory into r2.
#
# The data file holds 1..8, so the expected result is 36 (0x24).
#
# Register use:
#   r0  src1/dst1 scratch: loaded value, constants, and the "la" work register
#   r1  index into data memory
#   r2  accumulator
#   r3  index - limit
#   r4  limit (8)
#   r5  address of the loop body
#   r6  address of the halt branch
#
# "la <dst> <label>" is the assembler pseudo instruction that loads a label's
# address into a register.  It builds the address 3 bits at a time through
# whichever register set_src1_dst1 last named, so that register must not be
# the destination.

set_src1_dst1 r4
imm 1
shl 3

set_src1_dst1 r0
la r5 loop
la r6 halt
set_b_target r5

loop:
set_data_address r1
ld r0
add r2
imm 1
add r1
mov0 r1
mov r3
mov0 r4
sub r3
condition_nz r3
b b

# halt: spin on this branch forever
halt:
set_b_target r6
b b
