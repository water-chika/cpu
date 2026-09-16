# gpu16 wide per lane accesses: v_ld16_g and v_st16_g, section 4.8.
#
# Section 7.4 item 5 asks for a correctness test for the wide accesses in
# isolation, "because a wide access has failure modes a well-behaved kernel
# never reaches".  gpu_global.s already covers the little-endian quad layout
# and the truncation of an unaligned address; what is left, and what is here,
# is the store side and the exec mask:
#
#   1. sixteen bytes per lane load, store somewhere else and come back
#      unchanged - 256 bytes moved by one instruction, which is four
#      transactions and four VGPRs at each end,
#   2. a masked v_ld16_g fills only the enabled lanes and leaves the other
#      lanes' whole quad alone,
#   3. a masked v_st16_g writes only the enabled lanes' sixteen bytes and
#      leaves the rest of the region as the data file left it.
#
# One access does double duty: the read-back of the round trip is itself the
# masked load, so the same instruction proves the store landed (lanes 4..7)
# and that the mask held (every other lane).

v_lane_id   v0                  # v0 = lane
v_shli      v1, v0, 4           # v1 = lane * 16
s_imm       s3, 0               # source region: the data file
s_imm       s4, 2048            # round trip destination
s_imm       s5, 2560            # masked store destination
s_imm       s6, 0x00f0          # lanes 4..7
s_rd_exec   s7                  # 0xffff, to restore with

# ---- 1. 256 bytes in, 256 bytes out
v_ld16_g    v4, v1, s3, 0       # v4..v7 = bytes 16*lane .. +15
s_waitcnt_g 0
v_st16_g    v4, v1, s4, 0
s_waitcnt_g 0

# ---- 2. read it back with only four lanes enabled, over a poisoned quad
v_imm       v12, 0x1111
v_imm       v13, 0x2222
v_imm       v14, 0x3333
v_imm       v15, 0x4444
s_wr_exec   s6
v_ld16_g    v12, v1, s4, 0
s_waitcnt_g 0
s_wr_exec   s7                  # lanes 4..7 = v4..v7, the rest still poison

# ---- 3. store the same quad with only four lanes enabled
s_wr_exec   s6
v_st16_g    v4, v1, s5, 0
s_waitcnt_g 0
s_wr_exec   s7
v_ld16_g    v8, v1, s5, 0       # lanes 4..7 = v4..v7, the rest is the data file
s_waitcnt_g 0

s_endpgm
