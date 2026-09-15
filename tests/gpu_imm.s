# gpu16 scalar unit: the section 4.3 immediate forms and the shifts.
#
# Immediate-form instructions reinterpret {Arg2, Arg3, Mod} as one signed
# 16 bit immediate at [15:0]; the s_shli/s_shri/s_sari family instead take
# the shift amount in Mod, which is why those three still have an Arg2 field
# that reads as zero.  Hexadecimal and negative immediates are both here
# because the assembler has to accept both spellings of the same 16 bits.

s_imm   s3, 0x00ff              # s3 = 000000ff
s_immh  s3, 0xabcd              # s3 = abcd00ff
s_imm   s4, -5                  # s4 = fffffffb

s_addi  s5,  s4, 3              # -5 + 3        = fffffffe
s_muli  s6,  s4, -2             # -5 * -2       = 0000000a
s_andi  s7,  s3, 0x000f         # abcd00ff & f  = 0000000f
s_ori   s8,  s3, 0x0f00         # abcd00ff | f00 = abcd0fff
s_xori  s9,  s3, -1             # ~abcd00ff     = 5432ff00

s_shli  s10, s4, 4              # fffffffb << 4 = ffffffb0
s_shri  s11, s4, 4              # fffffffb >> 4 = 0fffffff
s_sari  s12, s4, 4              # -5 >>> 4      = ffffffff

s_imm   s13, 4
s_shl   s14, s4, s13            # fffffffb << 4 = ffffffb0
s_shr   s15, s4, s13            # fffffffb >> 4 = 0fffffff

s_endpgm
