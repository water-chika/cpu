# gpu16 scalar unit: s_ld_g (section 4.8) against the 24 bit data address,
# plus the s_waitcnt_g every correct program is required to put between a
# load and its use (section 1.4 - memory results are not interlocked).

s_imm       s3, 0               # base
s_ld_g      s4, s3, 0           # [0]  = deadbeef
s_waitcnt_g 0
s_ld_g      s5, s3, 4           # [4]  = 00c0ffee
s_waitcnt_g 0
s_ld_g      s6, s3, 8           # [8]  = 12345678
s_waitcnt_g 0

s_imm       s7, 12              # the same address, in the base
s_ld_g      s8, s7, 0           # [12] = 0000002a
s_waitcnt_g 0

s_add       s9, s4, s6          # deadbeef + 12345678 = f0e21567
s_rd_sys    s11, 11             # perf_gmem_bytes, four words = 16

s_endpgm
