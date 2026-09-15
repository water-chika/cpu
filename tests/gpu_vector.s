# gpu16 vector unit: the lane-independent half of the section 4.6 ALU.
#
# Every instruction here runs with the launch mask exec = 0xffff (section
# 4.12), so all sixteen lanes are live and the only thing that differs between
# them is v_lane_id.  That is the point: a result that is the same in every
# lane proves nothing about a sixteen lane machine, so every register below is
# a function of the lane index.
#
# The exec mask is not exercised here at all - gpu_exec.s and gpu_divergent.s
# do that - and neither is anything that crosses lanes or touches an SGPR,
# which is gpu_lane.s.

        v_lane_id v0                    # l
        v_imm     v1, 3                 # 3 in every lane

        v_add     v2,  v0, v1           # l + 3
        v_sub     v3,  v2, v0           # 3, the long way round
        v_mul     v4,  v0, v1           # 3l
        v_and     v5,  v2, v1           # (l + 3) & 3
        v_or      v6,  v0, v1           # l | 3
        v_xor     v7,  v0, v1           # l ^ 3
        v_not     v8,  v0               # ~l
        v_neg     v9,  v2               # -(l + 3)
        v_mad     v10, v0, v1, v2       # 3l + (l + 3)

        v_shl     v11, v1, v0           # 3 << l, a per lane shift amount
        v_shri    v12, v11, 1           # (3 << l) >> 1, a shift from Mod
        v_min     v13, v0, v3           # min(l, 3)
        v_max     v14, v0, v3           # max(l, 3)
        v_sari    v15, v9, 2            # -(l + 3) >> 2, arithmetic

        s_endpgm
