# gpu16 per lane global stores: docs/gpu_isa.md sections 1.2, 3.1 and 4.8.
#
# Three things values alone can check about a store, and one about a load:
#
#   1. a full-exec v_st4_g round-trips through memory,
#   2. a masked v_st4_g leaves the disabled lanes' memory exactly as the data
#      file left it - section 1.2, "memory instructions issue a transaction
#      only for enabled lanes",
#   3. a masked v_ld4_g leaves the disabled lanes' *destination* alone, which
#      is the mirror rule and the one a lane-blind implementation passes by
#      accident,
#   4. a v_st_g writes one byte and not the word around it.
#
# The data file holds the byte at address a equal to a & 0xff, so every word
# this program does not write is known, and "did not write" is checkable.

v_lane_id   v0                  # v0 = lane
v_shli      v1, v0, 2           # v1 = lane * 4
s_imm       s3, 2048            # region 1: the round trip
s_imm       s4, 2560            # region 2: the masked store
s_imm       s5, 3072            # region 3: the byte store
s_imm       s6, 0x00ff          # lanes 0..7
s_imm       s8, 0xaaaa          # the odd lanes
s_rd_exec   s7                  # 0xffff, to restore with

# ---- 1. store sixteen distinct words and read them back
v_imm       v2, 0x1000
v_add       v2, v2, v0          # v2 = 0x1000 + lane
v_st4_g     v2, v1, s3, 0
s_waitcnt_g 0
v_ld4_g     v3, v1, s3, 0
s_waitcnt_g 0                   # v3 must equal v2 in every lane

# ---- 2. the same store with half the lanes disabled
v_imm       v4, 0x7700
v_add       v4, v4, v0          # v4 = 0x7700 + lane, in all sixteen lanes
s_wr_exec   s6
v_st4_g     v4, v1, s4, 0       # only lanes 0..7 may write
s_waitcnt_g 0
s_wr_exec   s7
v_ld4_g     v5, v1, s4, 0       # read all sixteen back with exec restored
s_waitcnt_g 0                   # lanes 8..15 must still hold the data file

# ---- 3. a masked load must not disturb the lanes it does not fill
v_imm       v6, 0x5555          # poison every lane
s_wr_exec   s8
v_ld4_g     v6, v1, s3, 0       # only the odd lanes load
s_waitcnt_g 0
s_wr_exec   s7                  # even lanes must still read 0x5555

# ---- 4. one byte, into the second byte of each word
v_imm       v7, 0x00aa
v_add       v7, v7, v0          # v7 = 0xaa + lane; only the low byte stores
v_st_g      v7, v1, s5, 1       # address = 3072 + 4*lane + 1
s_waitcnt_g 0
v_ld4_g     v9, v1, s5, 0       # bytes 0, 2 and 3 must be untouched
s_waitcnt_g 0

s_endpgm
