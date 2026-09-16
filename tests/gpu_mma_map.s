# gpu16's matrix unit, the lane-to-row mapping: docs/gpu_isa.md section 4.7.
#
# The same program as gpu_mma_sym.s with one difference that decides
# everything: the two fragments are unrelated matrices rather than one matrix
# and its transpose, so the product is asymmetric.  tests/gen_mma_expect.py
# refuses to emit the expectation unless at least 200 of the 240 off-diagonal
# entries differ from their mirror image, so there is nowhere for a
# transposition to hide.
#
# What that buys, mutation by mutation.  Each of these is a change to the RTL
# that gpu_mma_sym.s cannot see:
#
#   * swap the two operands of the matrix unit - read `vB` across lanes and
#     `vA` per lane - and the machine computes the transpose of the right
#     answer;
#   * read the A fragment from the *lane* rather than from the accumulator row
#     being walked, i.e. drop section 4.7's 16:1 multiplexer, and every
#     accumulator row becomes the same row;
#   * write accumulator row m into a[m+1], or into the other block, and the
#     tile slides.
#
# Section 4.7's structural claim is that the A fragment crosses lanes through
# a 16:1 multiplexer and the B fragment does not cross lanes at all.  That
# claim is what the area budget in section 7.5 is priced on, so it wants a
# test that can tell the two operands apart.  This is that test.

s_imm       s3, 0x140           # Aa
s_imm       s4, 0x180           # Ba

v_lane_id   v14
v_shli      v15, v14, 2
v_ld4_g     v0, v15, s3, 0      # lane m = A row m
s_waitcnt_g 0
v_ld4_g     v1, v15, s4, 0      # lane n = B column n
s_waitcnt_g 0

mma_i8_z    A0, v0, v1          # D = Aa * Ba, asymmetric

acc_rd      v0, 0
acc_rd      v1, 1
acc_rd      v2, 2
acc_rd      v3, 3
acc_rd      v4, 4
acc_rd      v5, 5
acc_rd      v6, 6
acc_rd      v7, 7
acc_rd      v8, 8
acc_rd      v9, 9
acc_rd      v10, 10
acc_rd      v11, 11
acc_rd      v12, 12
acc_rd      v13, 13
acc_rd      v14, 14
acc_rd      v15, 15

s_endpgm
