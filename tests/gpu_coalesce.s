# gpu16 global coalescing: docs/gpu_isa.md section 3.1's transaction rule,
# measured rather than assumed.
#
# "The hardware sorts them into distinct aligned 64-byte blocks and issues one
# transaction per distinct block."  A test that only checks the values a load
# brings back cannot tell a machine that obeys that sentence from one that
# issues sixteen transactions every time, because both return the same data.
# So this program reads `perf_gmem_trans` (system register 13) either side of
# five accesses of known shape and keeps the differences, and reads
# `perf_cycles` either side of two of them to show the cost is real and not
# just a counter being incremented in a comment.
#
#   s5  lane*4  4 bytes  = 64 B inside one block          ->  1 transaction
#   s6  lane*64 4 bytes  = one block per lane             -> 16 transactions
#   s7  lane*8  4 bytes  = two blocks, eight lanes each   ->  2 transactions
#   s8  lane*16 16 bytes = 256 B, four blocks             ->  4 transactions
#   s9  lane*4  4 bytes stored, back to one block         ->  1 transaction
#
# s10 and s11 are the cycles the first two cost.  They differ by exactly 15,
# one per extra transaction, which is the 64 B/cycle port of section 3.1.
# The constant either side of that difference includes one cycle for the
# registered read port gpu16_gmem needs in order to be a block RAM.
#
# s6 is section 3.1's second worked example - "16 lanes reading 4 bytes each
# at stride lda (a matrix column walk): 16 transactions, 1/16 rate" - and it
# is the reason the GEMM kernel of section 5.3 is written the way it is.

v_lane_id   v0
v_shli      v1, v0, 2           # lane * 4   contiguous
v_shli      v2, v0, 6           # lane * 64  one block per lane
v_shli      v3, v0, 3           # lane * 8   two blocks
v_shli      v4, v0, 4           # lane * 16  four blocks, at 16 bytes a lane
s_imm       s3, 0

# ---- 1. sixteen lanes, four bytes each, one aligned block
s_rd_sys    s4, 13
s_rd_sys    s10, 8
v_ld4_g     v5, v1, s3, 0
s_waitcnt_g 0
s_rd_sys    s5, 13
s_sub       s5, s5, s4
s_rd_sys    s12, 8
s_sub       s10, s12, s10

# ---- 2. the same load at stride 64: one block per lane
s_rd_sys    s4, 13
s_rd_sys    s11, 8
v_ld4_g     v6, v2, s3, 0
s_waitcnt_g 0
s_rd_sys    s6, 13
s_sub       s6, s6, s4
s_rd_sys    s12, 8
s_sub       s11, s12, s11

# ---- 3. stride 8: lanes 0..7 in block 0, lanes 8..15 in block 1
s_rd_sys    s4, 13
v_ld4_g     v7, v3, s3, 0
s_waitcnt_g 0
s_rd_sys    s7, 13
s_sub       s7, s7, s4

# ---- 4. sixteen bytes a lane: 256 bytes is four transactions however it is
#         issued, which is section 4.8's "a wide access is a scheduling win,
#         not a bandwidth win".
s_rd_sys    s4, 13
v_ld16_g    v8, v4, s3, 0
s_waitcnt_g 0
s_rd_sys    s8, 13
s_sub       s8, s8, s4

# ---- 5. a store coalesces by the same rule
s_rd_sys    s4, 13
v_st4_g     v5, v1, s3, 0
s_waitcnt_g 0
s_rd_sys    s9, 13
s_sub       s9, s9, s4

# ---- the totals: 64+64+64+256+64 bytes asked for, 24 transactions to move
s_rd_sys    s12, 11
s_rd_sys    s13, 13

s_endpgm
