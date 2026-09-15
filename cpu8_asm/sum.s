# Sum the whole of data.list into r2.
#
# data.list holds 1..16, so the expected result is 136 (0x88).  The limit and
# the data file have to agree: the loop used to run 32 times over a 14 entry
# file and summed uninitialised memory, which is why it ended with nothing
# worth asserting.
#
# Register use:
#   r0  src1/dst1 scratch: loaded value, constants, and the "la" work register
#   r1  index into data memory
#   r2  accumulator
#   r3  index - limit
#   r4  limit (16)
#   r5  address of the loop body
#   r6  address of the halt branch

set_src1_dst1 r4
imm 2
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
