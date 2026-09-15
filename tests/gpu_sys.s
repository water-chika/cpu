# gpu16 scalar unit: s_rd_sys (section 4.3), s_addpc, s_sar and s_nop.
#
# Launched with wave_id = 2, group_id_x = 5, group_id_y = 11.

        s_rd_sys s3, 0          # wave_id      = 2
        s_rd_sys s4, 1          # group_id_x   = 5
        s_rd_sys s5, 2          # group_id_y   = 11
        s_rd_sys s6, 3          # num_waves    = 4
        s_rd_sys s7, 4          # wave_width   = 16
        s_rd_sys s8, 5          # lds_size     = 8192

        s_addpc  s9, 0          # PC_next 7 + 0  = 7
        s_addpc  s10, -2        # PC_next 8 + -2 = 6

        s_imm    s11, -16
        s_imm    s12, 2
        s_sar    s13, s11, s12  # -16 >>> 2 = -4

        s_nop
        s_rd_sys s14, 9         # perf_instrs: PC 0..11 have retired = 12

        s_endpgm
