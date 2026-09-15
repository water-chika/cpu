# gpu16: the exec mask is load bearing, and this program is written so that a
# machine that ignored it would still get lane 0 right.
#
# Every mask below has bit 0 set, and every value written is the value lane 0
# should end up with.  So lane 0 alone cannot distinguish this machine from
# one where exec does nothing at all: the difference is entirely in lanes
# 1..15, which must keep the values they had before the mask narrowed.  A test
# that only looked at lane 0 - which is what a scalar habit produces - would
# pass against hardware with no mask in it.
#
# Two of the checks are in the other direction and catch a mask that is
# applied where it should not be: v_cmp_* reads every lane regardless of exec,
# and v_readlane and v_bpermute do too (section 1.2).

        v_imm     v0, 42                # 42 in all sixteen lanes, exec = 0xffff

        s_imm     s3, 1
        s_wr_exec s3                    # exec = 0x0001: lane 0 alone

        v_add     v0, v0, v0            # lane 0 -> 84, the rest stay 42
        v_imm     v1, 7                 # lane 0 -> 7, the rest stay 0
        v_lane_id v2                    # lane 0 -> 0, which is also what an
                                        # unwritten lane holds; the other
                                        # fifteen would be non zero if the
                                        # mask leaked

        s_imm     s4, 0x8001              # sign extended, so s4 = 0xffff8001
        s_wr_exec s4                    # exec is s4[15:0] = 0x8001: lanes
                                        # 0 and 15

        v_imm     v3, 5                 # two lanes, not sixteen and not one
        v_writelane v4, s3, 3           # lane 3 is disabled: nothing happens
        v_writelane v5, s3, 0           # lane 0 is enabled: it does

        v_cmp_nz  s5, v0                # every lane holds 42 or 84, so the
                                        # condition is true everywhere and the
                                        # answer is exec itself: 0x8001

        s_exec_all                      # exec = 0xffff again

        v_cmp_nz  s6, v1                # 0x0001: only lane 0 was written
        v_cmp_nz  s7, v2                # 0x0000: v2 is zero in every lane
        v_readlane s8, v0, 5            # lane 5 was masked off, and still
                                        # reads back the 42 it kept

        s_rd_exec s9

        s_endpgm
