# gpu16: a divergent if/else, written the way section 1.3 says to write one.
#
# There is no reconvergence stack and no per-lane PC in this machine, so the
# whole of divergence is the four instructions below: a compare that makes a
# mask, s_and_saveexec to narrow exec while keeping the old value, s_wr_exec
# of the complement for the else side, and s_wr_exec of the saved mask to
# reconverge.  This program is section 1.3's worked example with both halves
# of the wave taking a different path and computing a different answer.
#
#   lanes 8..15 (the 'then' side):  v2 = 100 + l
#   lanes 0..7  (the 'else' side):  v2 = 200 - l
#
# Neither answer is a prefix of the other and neither is what the other side's
# code would have produced, so a wave that ran one side with the wrong mask
# cannot land on this final state.  The v_add after reconvergence then has to
# hit all sixteen lanes, which is what pins the restore.

        v_lane_id v0                    # l
        v_addi    v1, v0, -7            # > 0 exactly for lanes 8..15
        v_imm     v2, 0

        v_cmp_gz  s4, v1                # s4 = 0xff00
        s_and_saveexec s5, s4           # s5 = 0xffff, exec = 0xff00
        s_cbr_execz else_part           # not taken: eight lanes are live

        v_imm     v2, 100
        v_add     v2, v2, v0            # 100 + l, in the top half only

else_part:
        s_xor     s4, s5, s4            # the entry lanes not in the 'then' set
        s_wr_exec s4                    # exec = 0x00ff
        s_cbr_execz endif               # not taken: the other eight are live

        v_imm     v2, 200
        v_sub     v2, v2, v0            # 200 - l, in the bottom half only

endif:
        s_wr_exec s5                    # reconverge on the entry mask

        v_add     v3, v2, v2            # every lane, both answers doubled
        s_rd_exec s6                    # 0xffff again

        s_endpgm
