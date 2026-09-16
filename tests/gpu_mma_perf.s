# gpu16's matrix unit, the cost rather than the contents: docs/gpu_isa.md
# sections 4.7 and 7.2.
#
# Section 4.7: "One instruction is 1024 MACs (16 x 16 x 4).  The hardware is
# 64 int8 MACs wide (16 lanes x 4 k) and the instruction occupies the matrix
# unit for 16 cycles, one accumulator row per cycle."  Every throughput number
# in section 7 is that sentence multiplied out - 1024 matrix cycles per
# workgroup iteration, 90.7% matrix utilisation on gemm256 - and no value this
# machine computes can see it.  A matrix unit that took 32 cycles, or 256,
# would return exactly the numbers gpu_mma.s checks.
#
# So this program reads the clock and the counters around known stretches of
# work.  Three claims, each a single number:
#
#   1. `perf_mma_busy` (system register 10) is zero before any `mma_i8`, and
#      still zero after an `acc_zero`.  Zeroing a block walks the accumulator
#      file's write port for sixteen cycles but asks the 64 MACs for nothing,
#      and section 7.2's matrix utilisation is about the MACs.
#   2. Eight back-to-back `mma_i8` add exactly 8 * 16 = 128 to it.  That is
#      the "16 cycles, one accumulator row per cycle" claim, counted.
#   3. The same eight cost 131 cycles of wall clock between the two readings
#      of `perf_cycles`: the first `mma_i8`'s issue cycle, 128 cycles of
#      matrix occupancy with the next instruction's issue slot overlapping the
#      last cycle of the previous one's walk, and then the `acc_rd` that must
#      wait for the final row plus the `s_rd_sys` that reports.  If the
#      instructions did not overlap at all it would be 139, and if the unit
#      were not interlocked the `acc_rd` would not have waited.
#
# The `acc_zero` stretch is measured the same way and must be 19 = 1 + 16 + 2,
# which is where the claim that `acc_zero` is also a sixteen row walk - and
# not a magic single-cycle clear of 256 words - is pinned down.
#
# The expectation is computed in tests/gen_mma_expect.py from section 4.7's
# cycle count and section 7.2's Model-A, not measured from this machine.

s_imm       s3, 0x000
s_imm       s4, 0x040

v_lane_id   v14
v_shli      v15, v14, 2
v_ld4_g     v0, v15, s3, 0
s_waitcnt_g 0
v_ld4_g     v1, v15, s4, 0
s_waitcnt_g 0

# ---- 1. nothing has used the MACs yet
s_rd_sys    s4, 10              # perf_mma_busy = 0

s_rd_sys    s11, 8              # the clock, before acc_zero
acc_zero    A0
acc_rd      v13, 0              # interlocked: cannot issue until row 15 lands
s_rd_sys    s12, 8
s_sub       s10, s12, s11       # 19 cycles for a sixteen row walk

s_rd_sys    s5, 10              # perf_mma_busy still 0: no MACs were used

# ---- 2 and 3. eight matrix instructions back to back
s_rd_sys    s6, 8
mma_i8      A0, v0, v1
mma_i8      A0, v0, v1
mma_i8      A0, v0, v1
mma_i8      A0, v0, v1
mma_i8      A0, v0, v1
mma_i8      A0, v0, v1
mma_i8      A0, v0, v1
mma_i8      A0, v0, v1
acc_rd      v13, 0              # waits for the eighth walk to finish
s_rd_sys    s7, 8
s_sub       s8, s7, s6          # 131 cycles
s_rd_sys    s9, 10              # perf_mma_busy = 128

s_endpgm
