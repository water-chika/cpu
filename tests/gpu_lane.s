# gpu16 vector unit: everything in section 4.6 that leaves its own lane or
# touches the scalar register file.
#
# exec is 0xffff throughout, so this is about the data paths between the two
# register files and between lanes: the scalar operand forms, the cross lane
# read v_bpermute and v_readlane share, the single lane write of v_writelane,
# the four compares, and v_dot4.
#
# The compares are all taken against v5 = l - 5, so that each of the four
# conditions has a different and non-trivial answer: 5 lanes below zero, one
# lane at zero and ten above it.

        s_imm     s3, 10
        s_imm     s4, -2

        v_lane_id v0                    # l
        v_mov     v1, v0                # l again, through v_mov
        v_mov_s   v2, s3                # 10 broadcast to every lane
        v_add_s   v3, v0, s3            # l + 10
        v_mul_s   v4, v0, s4            # -2l
        v_addi    v5, v0, -5            # l - 5

        v_shli    v6, v0, 4             # l << 4
        v_shr     v7, v6, v1            # (l << 4) >> l
        v_sar     v8, v4, v1            # (-2l) >> l, arithmetic

        v_imm     v9, 0x0102            # bytes 02 01 00 00 in every lane
        v_dot4    v10, v9, v9, v0       # l + (2*2 + 1*1) = l + 5

        v_imm     v11, 15
        v_sub     v12, v11, v0          # 15 - l, the lane reversal index
        v_bpermute v13, v3, v12         # v3 from lane 15-l = 25 - l

        v_readlane  s5, v3, 7           # 7 + 10 = 17
        v_writelane v14, s3, 4          # lane 4 only, and only lane 4

        v_cmp_gz  s6, v5                # l > 5  -> 0xffc0
        v_cmp_z   s7, v5                # l == 5 -> 0x0020
        v_cmp_lz  s8, v5                # l < 5  -> 0x001f
        v_cmp_nz  s9, v5                # l != 5 -> 0xffdf

        s_rd_exec s10                   # nothing above touched exec

        s_endpgm
