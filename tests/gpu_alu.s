# gpu16 scalar unit: the section 4.3 register-register ALU.
#
# Launched with s0 = 0x1000, group_id_x = 7, group_id_y = 9, so this also
# pins down section 4.12's launch state.

s_imm  s3, 5
s_imm  s4, 3

s_and  s5,  s3, s4      # 5 & 3 = 1
s_or   s6,  s3, s4      # 5 | 3 = 7
s_xor  s7,  s3, s4      # 5 ^ 3 = 6
s_add  s8,  s3, s4      # 5 + 3 = 8
s_sub  s9,  s3, s4      # 5 - 3 = 2
s_mul  s10, s3, s4      # 5 * 3 = 15
s_not  s11, s3          # ~5    = fffffffa
s_neg  s12, s3          # -5    = fffffffb
s_mov  s13, s3          #       = 5
s_min  s14, s3, s4      # min   = 3
s_max  s15, s3, s4      # max   = 5

s_endpgm
