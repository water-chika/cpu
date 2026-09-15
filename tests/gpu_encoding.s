# Every instruction docs/gpu_isa.md defines, encoded.
#
# gpu16.v is scalar only, so simulation can reach about a third of this list.
# The rest - the vector ALU, the matrix unit, LDS, the exec mask - is held
# down here instead: assemble the source, compare the words against
# gpu_encoding.expect32, and an instruction no core can run yet still cannot
# change its encoding without someone noticing.
#
# The operands are chosen so that a field swapped with its neighbour cannot
# pass: Arg0 is 1, Arg1 is 2, Arg2 is 3, Arg3 is 4, and every Mod field has a
# value of its own.  Quad operands use v4 because section 4.8 allows only
# 0, 4, 8 and 12.
#
# In opcode order, which is also section 4.3 to section 4.10 order.


# ---- section 4.3, scalar ALU and system registers
s_and         s1, s2, s3
s_or          s1, s2, s3
s_not         s1, s2
s_xor         s1, s2, s3
s_add         s1, s2, s3
s_sub         s1, s2, s3
s_neg         s1, s2
s_mul         s1, s2, s3
s_mov         s1, s2
s_imm         s1, 0x1234
s_ori         s1, s2, 0x1234
s_shli        s1, s2, 7
s_shri        s1, s2, 7
s_sari        s1, s2, 7
s_addpc       s1, 0x1234
s_shl         s1, s2, s3
s_shr         s1, s2, s3
s_sar         s1, s2, s3
s_min         s1, s2, s3
s_max         s1, s2, s3
s_immh        s1, 0x1234
s_addi        s1, s2, 0x1234
s_muli        s1, s2, 0x1234
s_andi        s1, s2, 0x1234
s_xori        s1, s2, 0x1234
s_rd_sys      s1, 4

# ---- section 4.4, scalar control flow
s_bnz         s2, s3
s_bz          s2, s3
s_b           s3
s_blz         s2, s3
s_bgz         s2, s3
s_bnz_i       s2, 0x1234
s_bz_i        s2, 0x1234
s_b_i         0x1234
s_call        s1, 0x1234
s_cbr_execz   0x1234
s_cbr_execnz  0x1234

# ---- section 4.5, exec mask control
s_rd_exec     s1
s_wr_exec     s2
s_and_saveexec s1, s2
s_or_saveexec s1, s2
s_xor_saveexec s1, s2
s_exec_all    

# ---- section 4.6, vector ALU
v_and         v1, v2, v3
v_or          v1, v2, v3
v_not         v1, v2
v_xor         v1, v2, v3
v_add         v1, v2, v3
v_sub         v1, v2, v3
v_neg         v1, v2
v_mul         v1, v2, v3
v_mad         v1, v2, v3, v4
v_shl         v1, v2, v3
v_shr         v1, v2, v3
v_sar         v1, v2, v3
v_mov         v1, v2
v_mov_s       v1, s2
v_imm         v1, 0x1234
v_add_s       v1, v2, s3
v_mul_s       v1, v2, s3
v_shli        v1, v2, 7
v_shri        v1, v2, 7
v_sari        v1, v2, 7
v_min         v1, v2, v3
v_max         v1, v2, v3
v_dot4        v1, v2, v3, v4
v_lane_id     v1
v_addi        v1, v2, 0x1234
v_readlane    s1, v2, 11
v_writelane   v1, s2, 11
v_bpermute    v1, v2, v3
v_cmp_nz      s1, v2
v_cmp_z       s1, v2
v_cmp_lz      s1, v2
v_cmp_gz      s1, v2

# ---- section 4.7, matrix and accumulator
mma_i8        A1, v2, v3
acc_zero      A1
acc_rd        v1, 21
acc_wr        v2, 21
mma_i8_z      A1, v2, v3

# ---- section 4.8, global memory
v_ld_g        v1, v2, s3, 92
v_ld_gs       v1, v2, s3, 92
v_ld4_g       v1, v2, s3, 92
v_st_g        v1, v2, s3, 92
v_st4_g       v1, v2, s3, 92
s_ld_g        s1, s3, 92
v_ld16_g      v4, v2, s3, 92
v_st16_g      v4, v2, s3, 92

# ---- section 4.9, LDS
v_ld_l        v1, v2, s3, 92
v_ld4_l       v1, v2, s3, 92
v_st_l        v1, v2, s3, 92
v_st4_l       v1, v2, s3, 92

# ---- section 4.10, synchronisation and wave control
s_barrier     
s_waitcnt_g   3
s_waitcnt_l   3
s_endpgm      
s_nop         

# --------------------------------------------- section 4.11, worked by hand
#
# The document works twelve encodings out in prose.  They are reproduced here
# exactly as it writes them, so the assembler is checked against the ISA's own
# arithmetic and not only against a reading of its tables.

mma_i8      A1, v1, v3      # 70113000
mma_i8      A0, v1, v3      # 70013000
s_imm       s9, 32          # 0c900020
v_ld4_l     v1, v7, s9, 12  # a117900c
v_ld16_g    v12, v9, s1, 0  # 86c91000
v_st16_g    v4, v8, s2, 0   # 87482000
v_add_s     v13, v13, s6    # 4fdd6000
acc_rd      v15, 17         # 72f00011
s_cbr_execz 6               # 29000006
v_cmp_gz    s4, v6          # 5f460000
s_waitcnt_g 0               # b1000000
s_waitcnt_l 3               # b2000003
