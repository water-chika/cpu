# gpu16 per lane global loads: docs/gpu_isa.md sections 3.1, 4.2 and 4.8.
#
# The data file holds the byte at address `a` equal to `a & 0xff`, so every
# expected word below is a function of its address and nothing else, and a
# load that lands one byte or one lane out of place cannot match.
#
# Effective address is `v[Arg1] + s[Arg2] + zext(Mod)` (section 4.2), and all
# three terms are used here rather than left at zero: the per lane part in a
# VGPR, the region base in an SGPR and the offset in Mod.

v_lane_id   v0                  # v0 = lane
v_shli      v1, v0, 2           # v1 = lane * 4
s_imm       s3, 0               # region base: the bottom of memory
s_imm       s4, 256             # region base: the quad region

# Sixteen lanes, four consecutive bytes each, from a 64 byte aligned base.
# Section 3.1's first worked example, and the one access shape the whole
# memory system is designed around.
v_ld4_g     v2, v1, s3, 0
s_waitcnt_g 0

# The same sixteen words asked for two bytes further up.  Section 4.8
# truncates a 4 byte address down to a multiple of 4, so v3 must come out
# identical to v2 rather than straddling two words.
v_ld4_g     v3, v1, s3, 2
s_waitcnt_g 0

# One byte per lane, zero extended and then sign extended, from addresses
# 128..143 - deliberately the half of the byte range whose top bit is set, so
# that v_ld_g and v_ld_gs cannot agree with each other.
v_ld_g      v4, v0, s3, 128
s_waitcnt_g 0
v_ld_gs     v5, v0, s3, 128
s_waitcnt_g 0

# Sixteen bytes per lane into a VGPR quad: v8 takes bytes 0..3 of the lane's
# sixteen, v9 bytes 4..7, and so on (section 4.8, little-endian).
v_shli      v6, v0, 4           # v6 = lane * 16
v_ld16_g    v8, v6, s4, 0
s_waitcnt_g 0

# The same sixteen bytes, asked for seven bytes further up.  Section 4.8
# truncates the address down to a multiple of 16, so v12..v15 must come out
# identical to v8..v11 rather than rotated or offset.
v_ld16_g    v12, v6, s4, 7
s_waitcnt_g 0

s_endpgm
