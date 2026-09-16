# gpu16 LDS banking: docs/gpu_isa.md section 3.2, measured rather than
# assumed.
#
# "One wave-wide 4-byte access completes in one cycle if the 16 lane addresses
# hit 16 distinct banks, otherwise it takes one cycle per conflicting way."
# Values cannot see that sentence: a machine that serialises every LDS access
# into sixteen cycles returns exactly the same data as one that banks
# properly, and so does a machine that ignores banking and serves all sixteen
# lanes at once.  So this program reads `perf_lds_cycles` (system register 12,
# "LDS port cycles consumed") either side of six accesses whose bank pattern
# is known, and keeps the differences.
#
#   s4   stride 4,  lane m -> bank m            16 banks, 1 lane each ->  1
#   s5   stride 36, lane m -> bank (9m) & 15    16 banks, 1 lane each ->  1
#   s6   stride 32, lane m -> bank (8m) & 15     2 banks, 8 lanes each ->  8
#   s7   stride 8,  lane m -> bank (2m) & 15     8 banks, 2 lanes each ->  2
#   s8   stride 32, stored rather than loaded                         ->  8
#
# The two strides in the middle are section 3.2's whole argument.  A tile row
# stride of 32 bytes is the natural one and `32/4 = 8` shares a factor of 8
# with 16, so sixteen lanes reading sixteen rows land in two banks; padding
# the stride to 36 makes `36/4 = 9`, which is coprime with 16, so the same
# sixteen lanes land in sixteen banks.  That is why section 5.3 pays 2304 B
# instead of 2048 B for its `A` tile, and s5 against s6 is the whole of it:
# one cycle against eight.
#
# s9 and s10 are what the first and third accesses cost in `perf_cycles`,
# measured over identical instruction sequences so that only the access
# differs.  They come out 7 and 14 - one cycle per way, on top of the six
# cycles the surrounding instructions take either way - which is the evidence
# that `perf_lds_cycles` is counting something real and not just being
# incremented in a comment.
#
# s11 is the total: 1+1 + 1+1 + 8+8 + 2+2 = 24 port cycles for the eight
# accesses, stores included.
#
# Nothing here checks a value.  Every region is written before it is read so
# that the loads have something defined to return, but what they return is
# gpu_lds.s's job.

v_lane_id   v0
v_shli      v1, v0, 2           # lane * 4,  one lane per bank
s_imm       s13, 36
v_mul_s     v2, v0, s13         # lane * 36, section 3.2's padded row stride
v_shli      v3, v0, 5           # lane * 32, the natural row stride
v_shli      v4, v0, 3           # lane * 8,  two lanes per bank
v_imm       v5, 0x0055          # payload; this test does not check values

# ---- 1. stride 4: sixteen lanes, sixteen banks, one cycle
s_imm       s3, 0
v_st4_l     v5, v1, s3, 0
s_waitcnt_l 0
s_rd_sys    s12, 12
s_rd_sys    s9, 8
v_ld4_l     v6, v1, s3, 0
s_waitcnt_l 0
s_rd_sys    s4, 12
s_sub       s4, s4, s12
s_rd_sys    s12, 8
s_sub       s9, s12, s9

# ---- 2. stride 36: a padded tile row, also sixteen banks
s_imm       s3, 1024
v_st4_l     v5, v2, s3, 0
s_waitcnt_l 0
s_rd_sys    s12, 12
v_ld4_l     v7, v2, s3, 0
s_waitcnt_l 0
s_rd_sys    s5, 12
s_sub       s5, s5, s12

# ---- 3. stride 32: an unpadded tile row, two banks and eight ways
s_imm       s3, 2048
s_rd_sys    s12, 12
v_st4_l     v5, v3, s3, 0       # a store conflicts by the same rule
s_waitcnt_l 0
s_rd_sys    s8, 12
s_sub       s8, s8, s12
s_rd_sys    s12, 12
s_rd_sys    s10, 8
v_ld4_l     v8, v3, s3, 0
s_waitcnt_l 0
s_rd_sys    s6, 12
s_sub       s6, s6, s12
s_rd_sys    s12, 8
s_sub       s10, s12, s10

# ---- 4. stride 8: eight banks, two ways, the case between the other two
s_imm       s3, 4096
v_st4_l     v5, v4, s3, 0
s_waitcnt_l 0
s_rd_sys    s12, 12
v_ld4_l     v9, v4, s3, 0
s_waitcnt_l 0
s_rd_sys    s7, 12
s_sub       s7, s7, s12

# ---- the total
s_rd_sys    s11, 12

s_endpgm
