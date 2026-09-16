# gpu16's matrix unit under a whole workgroup: docs/gpu_isa.md sections 4.7
# and 7.3.
#
# Section 7.3 prices a GEMM workgroup iteration at "1024 matrix cycles per
# workgroup iteration" for four waves issuing sixteen `mma_i8` each.  That is
# 4 x 256, not 256, and the factor of four is a statement about the hardware:
# the 64 MACs are **one array for the compute unit**, and the four waves queue
# for it.  Everything downstream depends on it - the matrix unit being the
# limiter rather than the issue slot, the 90.7% utilisation figure, and the
# area budget in 7.5, which prices one array and four accumulator files.
#
# A single wave cannot tell the two machines apart: with nobody to contend
# with, a private array and a shared one both give sixteen cycles an
# instruction.  So this is the multi-wave test, and it makes two measurements
# that only the shared array passes.
#
#   * `perf_mma_busy` after every wave has finished must be 4 x 8 x 16 = 512.
#   * the stretch of wall clock containing that work must be **at least 512
#     cycles**, because 512 cycles of one array cannot be spent in fewer.
#     Four private arrays would do the same work in about 130 and s11 below
#     would come out zero.
#
# Both barriers matter.  The first one starts the four waves together, so the
# clock reading is about the matrix unit and not about how long the staging
# loads took; the second guarantees that when wave 0 reads the counters, every
# wave's last accumulator row has already landed.

s_imm       s3, 0x000
s_imm       s4, 0x040

v_lane_id   v14
v_shli      v15, v14, 2
v_ld4_g     v0, v15, s3, 0
s_waitcnt_g 0
v_ld4_g     v1, v15, s4, 0
s_waitcnt_g 0

s_waitcnt_l 0
s_barrier                       # all four waves start the stretch together

s_rd_sys    s6, 8               # the clock, before

mma_i8      A0, v0, v1
mma_i8      A0, v0, v1
mma_i8      A0, v0, v1
mma_i8      A0, v0, v1
mma_i8      A0, v0, v1
mma_i8      A0, v0, v1
mma_i8      A0, v0, v1
mma_i8      A0, v0, v1
acc_rd      v13, 0              # this wave's last row has landed

s_waitcnt_l 0
s_barrier                       # ... and so has every other wave's

s_rd_sys    s7, 8
s_sub       s8, s7, s6
s_rd_sys    s9, 10              # perf_mma_busy = 512, the whole workgroup's

# ---- and the same number seen from the clock: 512 array cycles cannot be
# spent in fewer than 512 cycles, whoever spent them.
s_imm       s13, 512
s_sub       s13, s8, s13
s_imm       s11, 0
la          s12, done
s_blz       s13, s12            # under 512: the waves were not sharing
s_imm       s11, 1

done:   s_endpgm
