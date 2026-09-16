# gpu16 global memory beyond the on-chip 4 KiB: docs/gpu_isa.md section 3
# ("global | 16 MiB | 24 bit byte address") against docs/fpga_bringup.md 4.7.
#
# The ISA has always claimed a 16 MiB global address space and `gpu16_cu` has
# always instantiated 1024 words of it, so every address above 4 KiB wrapped
# silently back into the bottom of the array.  Nothing noticed, because no
# checked-in test ever addressed above 4 KiB - and so none of section 7's
# benchmark kernels could run at any tier, since `gemm256` alone moves 1 MiB.
#
# This program is the test that notices.  It writes two different patterns to
# two regions three quarters of a megabyte apart, then reads both back:
#
#   region A at 0x60000 (384 KiB) - a gemm256 tile's worth up
#   region B at 0xf0000 (960 KiB) - near the top of the testbench's memory
#
# With the compute unit's own 1024 word memory both regions truncate to block
# 0, region B lands on top of region A, and the four readback registers come
# out equal.  They are not equal below, so passing this program *is* the proof
# that the working set is no longer capped - the memory the compute unit talks
# to is outside it and as large as whoever instantiated it made it.
#
# No data file: the program writes everything it reads.

# ---- region bases, built with the two halves of an immediate (section 4.5)
s_imm       s3, 0
s_immh      s3, 6               # s3 = 0x00060000, 384 KiB
s_imm       s4, 0
s_immh      s4, 15              # s4 = 0x000f0000, 960 KiB

v_lane_id   v0
v_shli      v1, v0, 2           # v1 = lane * 4, one word per lane

# ---- region A: sixteen words, each holding its own byte offset
v_st4_g     v1, v1, s3, 0
s_waitcnt_g 0

# ---- region B: a pattern that cannot be confused with region A's
v_shli      v3, v0, 8           # lane << 8
v_st4_g     v3, v1, s4, 0
s_waitcnt_g 0

# ---- read both back per lane.  If the regions aliased, v2 would hold
# region B's pattern instead of region A's.
v_ld4_g     v2, v1, s3, 0
s_waitcnt_g 0
v_ld4_g     v4, v1, s4, 0
s_waitcnt_g 0

# ---- and again through the scalar port, so the check does not depend on
# +vexpect alone.  Lane 15's word of each region: 0x3c and 0xf00.
s_ld_g      s5, s3, 60
s_waitcnt_g 0
s_ld_g      s6, s4, 60
s_waitcnt_g 0

# Lane 0's word of region A is 0 and of region B is 0, so a third probe takes
# lane 1: 4, and 0x100.
s_ld_g      s7, s3, 4
s_waitcnt_g 0
s_ld_g      s8, s4, 4
s_waitcnt_g 0

# The difference is what aliasing would destroy: 0xf00 - 0x3c = 0xec4.
s_sub       s9, s6, s5

s_endpgm
