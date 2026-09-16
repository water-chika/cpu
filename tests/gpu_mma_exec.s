# gpu16's matrix unit under a narrowed exec mask: docs/gpu_isa.md section 4.7.
#
# "`vA` is read from all 16 lanes regardless of `exec`, but accumulators are
# updated only in lanes where `exec[n] = 1`.  Running `mma_i8` with
# `exec != 0xFFFF` is legal but the A-fragment rows of disabled lanes still
# participate, which is a sharp edge (section 6)."
#
# Two rules in one sentence, pulling in opposite directions, and a machine can
# get either one wrong on its own:
#
#   * a unit that ignored `exec` on the accumulator write would overwrite the
#     eight disabled lanes' poison;
#   * a unit that also applied `exec` to the cross lane A read - the tempting
#     symmetry - would leave the eight accumulator rows belonging to disabled
#     lanes holding zero, or holding the poison, instead of a real product.
#
# So every one of the sixteen rows is computed here, including the eight that
# only a disabled lane could have supplied, and only the eight enabled lanes'
# words of them are written.  tests/gen_mma_expect.py asserts that those rows
# really are different from the poison before it emits the expectation, which
# is what stops the test from passing vacuously.
#
# exec is 0x0f0f rather than 0x00ff so that enabled and disabled lanes
# interleave twice: a unit that masked the wrong half, or shifted the mask,
# cannot match.

s_imm       s3, 0x140           # Aa
s_imm       s4, 0x180           # Ba

v_lane_id   v14
v_shli      v15, v14, 2
v_ld4_g     v0, v15, s3, 0
s_waitcnt_g 0
v_ld4_g     v1, v15, s4, 0
s_waitcnt_g 0

# ---- poison the whole block, every lane, while exec is still 0xffff
v_addi      v2, v14, 0x6000
acc_wr      v2, 0
v_addi      v2, v14, 0x6010
acc_wr      v2, 1
v_addi      v2, v14, 0x6020
acc_wr      v2, 2
v_addi      v2, v14, 0x6030
acc_wr      v2, 3
v_addi      v2, v14, 0x6040
acc_wr      v2, 4
v_addi      v2, v14, 0x6050
acc_wr      v2, 5
v_addi      v2, v14, 0x6060
acc_wr      v2, 6
v_addi      v2, v14, 0x6070
acc_wr      v2, 7
v_addi      v2, v14, 0x6080
acc_wr      v2, 8
v_addi      v2, v14, 0x6090
acc_wr      v2, 9
v_addi      v2, v14, 0x60a0
acc_wr      v2, 10
v_addi      v2, v14, 0x60b0
acc_wr      v2, 11
v_addi      v2, v14, 0x60c0
acc_wr      v2, 12
v_addi      v2, v14, 0x60d0
acc_wr      v2, 13
v_addi      v2, v14, 0x60e0
acc_wr      v2, 14
v_addi      v2, v14, 0x60f0
acc_wr      v2, 15

# ---- eight lanes on, eight off, interleaved
s_imm       s5, 0x0f0f
s_wr_exec   s5
s_rd_exec   s7                  # 0x0f0f: the mask the mma actually ran under

mma_i8_z    A0, v0, v1

# ---- reconverge before reading back, or the read itself would be masked
s_exec_all
s_rd_exec   s8                  # 0xffff

acc_rd      v0, 0
acc_rd      v1, 1
acc_rd      v2, 2
acc_rd      v3, 3
acc_rd      v4, 4
acc_rd      v5, 5
acc_rd      v6, 6
acc_rd      v7, 7
acc_rd      v8, 8
acc_rd      v9, 9
acc_rd      v10, 10
acc_rd      v11, 11
acc_rd      v12, 12
acc_rd      v13, 13
acc_rd      v14, 14
acc_rd      v15, 15

s_endpgm
