# gpu16's matrix unit, the two ways of starting a tile: docs/gpu_isa.md
# section 4.7's `acc_zero` and `mma_i8_z`.
#
# A machine that only had `mma_i8` would need the accumulators to already hold
# the right thing, and section 4.7 gives two ways of arranging that:
#
#   `acc_zero blk`      zero a whole block, then accumulate onto it;
#   `mma_i8_z blk, ...` `D = A * B` - the same shapes, overwriting.
#
# The two must produce the same tile, and this program says so in the strongest
# way available: both blocks are first filled with a lane-dependent poison
# through `acc_wr`, then A0 is zeroed and accumulated onto while A1 is
# overwritten, and the sixteen rows are subtracted from one another in the
# machine itself.  `v_cmp_nz` turns each difference into a lane mask and the
# masks are ORed into s8, so s8 is zero only if all 256 differences are zero -
# a check that does not depend on the expectation file being right.
#
# The poison matters.  Zero-initialised accumulators would make `acc_zero`
# untestable and `mma_i8_z` indistinguishable from `mma_i8`; 0x5a5a + lane is
# neither zero nor uniform, so a block that was not cleared, or was cleared in
# only some lanes, cannot pass.

s_imm       s3, 0x000           # A1 fragment
s_imm       s4, 0x040           # B1 fragment

v_lane_id   v14
v_shli      v15, v14, 2
v_ld4_g     v0, v15, s3, 0
s_waitcnt_g 0
v_ld4_g     v1, v15, s4, 0
s_waitcnt_g 0

# ---- poison every one of the 32 accumulators, in both blocks
v_addi      v2, v14, 0x5a5a
acc_wr      v2, 0
acc_wr      v2, 1
acc_wr      v2, 2
acc_wr      v2, 3
acc_wr      v2, 4
acc_wr      v2, 5
acc_wr      v2, 6
acc_wr      v2, 7
acc_wr      v2, 8
acc_wr      v2, 9
acc_wr      v2, 10
acc_wr      v2, 11
acc_wr      v2, 12
acc_wr      v2, 13
acc_wr      v2, 14
acc_wr      v2, 15
acc_wr      v2, 16
acc_wr      v2, 17
acc_wr      v2, 18
acc_wr      v2, 19
acc_wr      v2, 20
acc_wr      v2, 21
acc_wr      v2, 22
acc_wr      v2, 23
acc_wr      v2, 24
acc_wr      v2, 25
acc_wr      v2, 26
acc_wr      v2, 27
acc_wr      v2, 28
acc_wr      v2, 29
acc_wr      v2, 30
acc_wr      v2, 31

# ---- the two routes to the same tile
acc_zero    A0                  # sixteen rows of zeroes, one per cycle
mma_i8      A0, v0, v1          # 0 + A*B
mma_i8_z    A1, v0, v1          # A*B, straight over the poison

# ---- and the machine's own opinion of whether they agree
s_imm       s8, 0
acc_rd      v13, 0
acc_rd      v12, 16
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 1
acc_rd      v12, 17
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 2
acc_rd      v12, 18
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 3
acc_rd      v12, 19
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 4
acc_rd      v12, 20
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 5
acc_rd      v12, 21
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 6
acc_rd      v12, 22
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 7
acc_rd      v12, 23
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 8
acc_rd      v12, 24
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 9
acc_rd      v12, 25
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 10
acc_rd      v12, 26
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 11
acc_rd      v12, 27
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 12
acc_rd      v12, 28
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 13
acc_rd      v12, 29
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 14
acc_rd      v12, 30
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7
acc_rd      v13, 15
acc_rd      v12, 31
v_sub       v11, v13, v12
v_cmp_nz    s7, v11
s_or        s8, s8, s7

# ---- block A1, the overwritten one, is what +vexpect checks by value
acc_rd      v0, 16
acc_rd      v1, 17
acc_rd      v2, 18
acc_rd      v3, 19
acc_rd      v4, 20
acc_rd      v5, 21
acc_rd      v6, 22
acc_rd      v7, 23
acc_rd      v8, 24
acc_rd      v9, 25
acc_rd      v10, 26
acc_rd      v11, 27
acc_rd      v12, 28
acc_rd      v13, 29
acc_rd      v14, 30
acc_rd      v15, 31

s_endpgm
