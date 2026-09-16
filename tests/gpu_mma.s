# gpu16's matrix unit, the value half: docs/gpu_isa.md sections 2.3 and 4.7.
#
# One `mma_i8` is `D += A * B` with A a 16x4 int8 fragment, B a 4x16 one and D
# the 16x16 int32 accumulator block - 1024 MACs in one instruction word.  The
# operand layout is the thing to keep straight, because it is asymmetric and
# every plausible way of getting it wrong still produces a matrix of plausible
# numbers:
#
#   * `vB` is read **per lane**: lane n holds B[k][n] for k = 0..3, four
#     packed int8, k = 0 in the low byte.
#   * `vA` is read **across lanes**: lane m holds A[m][k], and the unit reads
#     the whole 32-bit word out of lane m on the cycle it walks accumulator
#     row m.
#   * the accumulator stays in its lane: `a[16*blk + m]` in lane n is C[m][n].
#
# What this program checks, in order:
#
#   1. `acc_wr` puts a VGPR into one accumulator - the `C +=` start section
#      2.3 says the instruction exists for;
#   2. two `mma_i8` accumulate two K steps onto that start, so the final tile
#      is C0 + A1*B1 + A2*B2 and not any one of the three;
#   3. `acc_rd` brings all sixteen accumulators of the block back out.
#
# The seed C0[m][n] = 0x1000 + 16m + n is a function of both indices, so a
# tile written one accumulator out of place, or transposed, cannot match even
# before the products are added.  The expectation is computed by
# tests/gen_mma_expect.py from section 4.7's own loop.

s_imm       s3, 0x000           # A1, the first K step of A
s_imm       s4, 0x040           # B1
s_imm       s5, 0x080           # A2, the second K step
s_imm       s6, 0x0c0           # B2

v_lane_id   v14                 # v14 = lane
v_shli      v15, v14, 2         # v15 = lane * 4, one word per lane

v_ld4_g     v0, v15, s3, 0      # v0 = A1 fragment, lane m = row m
s_waitcnt_g 0
v_ld4_g     v1, v15, s4, 0      # v1 = B1 fragment, lane n = column n
s_waitcnt_g 0
v_ld4_g     v2, v15, s5, 0      # v2 = A2 fragment
s_waitcnt_g 0
v_ld4_g     v3, v15, s6, 0      # v3 = B2 fragment
s_waitcnt_g 0

# ---- 0. and fill the *other* block with something else entirely.  The
# accumulator number in `acc_rd`/`acc_wr` is five bits, section 4.7, so its
# top bit chooses the block just as `Arg0` does for `mma_i8`; a unit that
# dropped that bit would alias A1 onto A0 and quietly read this back.
v_addi      v12, v14, 0x7e00
acc_wr      v12, 0
acc_wr      v12, 1
acc_wr      v12, 2
acc_wr      v12, 3
acc_wr      v12, 4
acc_wr      v12, 5
acc_wr      v12, 6
acc_wr      v12, 7
acc_wr      v12, 8
acc_wr      v12, 9
acc_wr      v12, 10
acc_wr      v12, 11
acc_wr      v12, 12
acc_wr      v12, 13
acc_wr      v12, 14
acc_wr      v12, 15

# ---- 1. seed block A1: a[16+m] in lane n takes 0x1000 + 16m + n
v_addi      v13, v14, 0x1000
acc_wr      v13, 16
v_addi      v13, v14, 0x1010
acc_wr      v13, 17
v_addi      v13, v14, 0x1020
acc_wr      v13, 18
v_addi      v13, v14, 0x1030
acc_wr      v13, 19
v_addi      v13, v14, 0x1040
acc_wr      v13, 20
v_addi      v13, v14, 0x1050
acc_wr      v13, 21
v_addi      v13, v14, 0x1060
acc_wr      v13, 22
v_addi      v13, v14, 0x1070
acc_wr      v13, 23
v_addi      v13, v14, 0x1080
acc_wr      v13, 24
v_addi      v13, v14, 0x1090
acc_wr      v13, 25
v_addi      v13, v14, 0x10a0
acc_wr      v13, 26
v_addi      v13, v14, 0x10b0
acc_wr      v13, 27
v_addi      v13, v14, 0x10c0
acc_wr      v13, 28
v_addi      v13, v14, 0x10d0
acc_wr      v13, 29
v_addi      v13, v14, 0x10e0
acc_wr      v13, 30
v_addi      v13, v14, 0x10f0
acc_wr      v13, 31

# ---- 2. two K steps onto it.  No wait between them and no wait before the
# read-back: section 1.4 interlocks the accumulator file, so the hardware -
# not the program - is what has to get this right.
mma_i8      A1, v0, v1
mma_i8      A1, v2, v3

# ---- 3. the whole block back into the VGPRs, which is what +vexpect sees
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
