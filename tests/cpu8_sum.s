# Sum the first 8 bytes of data memory into r2.
#
# The data file holds 1..8, so the expected result is 36 (0x24).
#
# Register use:
#   r0  scratch / loaded value / constants
#   r1  index into data memory
#   r2  accumulator
#   r3  index - limit
#   r4  limit (8)
#   r6  address of the halt instruction

set_src1_dst1 r4
imm 1
shl 3

set_src1_dst1 r0

# loop start, address 4
set_data_address r1
ld r0
add r2
imm 1
add r1
mov0 r1
mov r3
mov0 r4
sub r3
imm 4
condition_nz r3
set_b_target r0
b b

# Padding so that the halt branch below lands on address 24, which is the
# only nearby address an "imm"/"shl" pair can build (3 << 3).  Once the
# assembler grows label support this can go away.
condition_1 condition_1
condition_1 condition_1
condition_1 condition_1

# halt: spin on the branch at address 24 forever
set_src1_dst1 r6
imm 3
shl 3
set_b_target r6
b b
