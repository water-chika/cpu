# gpu16's matrix unit, the symmetric control: docs/gpu_isa.md section 4.7.
#
# This test exists to be passed by a *wrong* machine, which is the only way to
# show what its partner gpu_mma_map is worth.
#
# `mma_i8_z A0, v0, v0` names the same VGPR as both fragments.  Lane m of v0
# is then A[m][k] read as the A fragment and B[k][m] read as the B fragment,
# so B = A transposed and the product is A * A^T - symmetric by construction.
#
# Now consider a matrix unit that has the two operands the wrong way round:
# one that reads the *B* register across lanes and the *A* register per lane.
# It computes (A * B)^T instead of A * B, which for this input is the same
# matrix, and every one of the 256 values below still matches.  The same is
# true of a unit that wrote accumulator row m into lane n and lane n's value
# into row m.  Neither bug is visible here, and that is the point: a test
# whose input is symmetric cannot see a transposition, so a suite that had
# only this one would be reporting the mapping as correct while it was not.
#
# gpu_mma_map.s is the same program with an asymmetric pair, and it fails for
# both of those mutations.  The two together are the evidence; either alone is
# not.

s_imm       s3, 0x100           # As, the symmetric case's fragment

v_lane_id   v14
v_shli      v15, v14, 2
v_ld4_g     v0, v15, s3, 0
s_waitcnt_g 0

mma_i8_z    A0, v0, v0          # D = As * As^T

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
