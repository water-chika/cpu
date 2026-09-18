# Check ld_p and st_p, the two instructions that reach program memory.
#
# The program rewrites one of its own instructions and then runs it.  The
# instruction at "patch" is assembled as "imm 0" (0x58) and the program turns
# it into "imm 7" (0x5f) without ever knowing what 0x58 is: it reads the byte
# back with ld_p, ors in the 7, and stores it with st_p.  The dst1 register in
# force there is r7, so r7 ends up holding 7 rather than 0.  The patched byte
# is then read a second time with ld_p, which is how the store is checked
# independently of the fetch.
#
# Field reminder: cpu8's program word is 8 bits, which is exactly one
# register, so unlike cpu16 there is no half to select:
#
#   st_p <src0>
#   ld_p <dst>
#
# and both take the address from the register set_data_address loaded, the
# same one ld and st use.
#
# Register use:
#   r0  address of the instruction being patched
#   r1  the scratch register "la" builds an address in
#   r2  the patch byte: read back, ored with 7, stored
#   r3  7, the bit the patch sets
#   r4  the byte read back after the store
#   r5  address of the halt branch
#   r7  0 unless the patched instruction really ran

set_src1_dst1 r1
la r0 patch
set_data_address r0
ld_p r2

set_src1_dst1 r3
imm 7
or r2
st_p r2
ld_p r4

set_src1_dst1 r1
la r5 halt
set_b_target r5

set_src1_dst1 r7

patch:
imm 0

halt:
b b
