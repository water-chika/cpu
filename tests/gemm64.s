# gemm64 - docs/gpu_isa.md section 7.1's smallest benchmark kernel, actually
# executed.
#
# C[64][64] = A[64][64] * Bt[64][64], int8 operands, int32 result, B already
# transposed.  This is section 5.3's kernel with the four corrections listed
# in section 7.4 applied: the accumulators are zeroed, the epilogue stores
# rather than accumulates, the grid is walked by the kernel itself because
# the testbench launches one workgroup, and `v_and` takes two vector sources.
#
# The tiling is section 5.1's, unchanged.  A workgroup of four waves owns a
# 64 x 32 tile of C and steps through K in panels of 32 bytes, double
# buffered in LDS at 0 and 4096 with a 36 byte row stride.  Wave w owns rows
# 32*(w>>1) and columns 16*(w&1) of the tile, which is 32 accumulators, and
# issues 16 `mma_i8` per k panel.  M = 64 is one workgroup tall, so the grid
# is 2 workgroups wide and each runs 2 k panels: exactly the "2 workgroups, 2
# iterations each" of the table in section 7.3.
#
# Registers, following section 5.2 except where the grid loop needs one:
#
#   s0  k counter, then an epilogue temporary
#   s1  fill pointer, then the C row stride
#   s2  temporary
#   s3  this wave's A fill base      s4  this wave's Bt fill base
#   s5  &C                           s6  K            s7  N
#   s8  8*K, the fill's row-group stride
#   s9  As read base                 s10 Bs read base
#   s11 LDS fill base (the buffer being staged into)
#   s12 wave id                      s13 group_id_x, walked by this kernel
#   s14 temporary, then the C pointer
#   s15 call link
#
#   v0  lane id          v1-v3 A0, A1 and B fragments for the even k step
#   v4-v6 the same for the odd step, so an LDS load overlaps an `mma`
#   v7  lane*36          v8  lane*36 + 576     (the two mma read offsets)
#   v9  global fill offset   v10 As fill offset   v11 Bs fill offset
#   v12-v15 the v_ld16_g staging quad, and v12 is lane*4 in the epilogue
#
# The waits are the ones the ISA requires, not the ones this implementation
# happens to need: a global load is followed by `s_waitcnt_g 0` before its
# quad is read even though section 4.8's memory completes before the next
# instruction issues, because a machine that overlapped them would still be
# running this program correctly.

        s_ld_g   s3,  s0, 0             # &A
        s_ld_g   s4,  s0, 4             # &Bt
        s_ld_g   s5,  s0, 8             # &C
        s_ld_g   s7,  s0, 16            # N
        s_ld_g   s6,  s0, 20            # K
        s_rd_sys s12, 0                 # wave id 0..3
        v_lane_id v0
        s_waitcnt_g 0

        s_imm    s13, 0                 # group_id_x, the grid loop counter
        s_muli   s8,  s6,  8            # 8*K

        # ---------------- per-wave global bases ----------------
        # M0 = 0: M = 64 is exactly one workgroup of rows.
        s_shli   s14, s12, 4            # 16*w
        s_mul    s14, s14, s6
        s_add    s3,  s3,  s14          # &A[16w][0]
        s_shli   s14, s12, 3            # 8*w
        s_mul    s14, s14, s6
        s_add    s4,  s4,  s14          # &Bt[8w][0]

        # ---------------- per-lane fill offsets ----------------
        # v_ld16_g moves 16 B per lane, so one access covers eight 32 byte
        # panel rows: lane l covers row l>>1, bytes (l&1)*16 .. +15.
        s_imm    s14, 1
        v_mov_s  v10, s14
        v_and    v10, v0,  v10          # l & 1
        v_shli   v10, v10, 4            # c = (l&1)*16
        v_shri   v9,  v0,  1            # r = l>>1
        v_mul_s  v11, v9,  s6           # r*K
        v_add    v9,  v11, v10          # v9 = r*K + c            (global)
        s_imm    s14, 36
        v_shri   v11, v0,  1
        v_mul_s  v11, v11, s14          # r*36
        v_add    v11, v11, v10          # r*36 + c
        s_muli   s14, s12, 576          # this wave's As rows start at 16w*36
        v_add_s  v10, v11, s14          # v10 = As fill offset
        s_muli   s14, s12, 288          # and its Bs rows at 8w*36
        s_addi   s14, s14, 2304
        v_add_s  v11, v11, s14          # v11 = Bs fill offset

        # ---------------- per-lane mma read offsets ----------------
        s_imm    s14, 36
        v_mul_s  v7,  v0,  s14          # lane*36
        v_addi   v8,  v7,  576          # lane*36 + 576, the second 16 rows

        # ---------------- compute-side tile bases, buffer 0 ----------------
        s_shri   s14, s12, 1
        s_shli   s14, s14, 5            # m_w = 32*(w>>1)
        s_muli   s9,  s14, 36
        s_andi   s14, s12, 1
        s_shli   s14, s14, 4            # n_w = 16*(w&1)
        s_muli   s10, s14, 36
        s_addi   s10, s10, 2304

# ================================================== one workgroup of the grid
gxpass:
        acc_zero A0                     # C is stored, not accumulated into,
        acc_zero A1                     # so the blocks start at zero
        s_andi   s9,  s9,  0x0fff       # back to buffer 0
        s_andi   s10, s10, 0x0fff
        s_imm    s11, 0
        s_mov    s0,  s6                # k counter = K

        # ---------------- prologue: fill buffer 0 ----------------
        s_call   s15, fill_tile
        s_addi   s3,  s3,  32
        s_addi   s4,  s4,  32
        s_imm    s11, 4096              # stage into the other buffer from now
        s_waitcnt_l 0
        s_barrier

# ================================================================= main loop
kloop:
        s_call   s15, fill_tile         # stage the next panel

        # Eight k steps of four, fully unrolled, with the loads for a step
        # issued *after* the `mma` pair of the step before it.  That order is
        # not decoration: `mma_i8` reads its A fragment one lane per cycle
        # across its sixteen cycle walk, so a load that lands in the fragment
        # registers of an `mma` still walking rewrites the rows it has not
        # reached yet.  Section 5.3's listing loads into the triple the
        # previous pair is still using; section 7.4 records what that costs.
        # Here the loads for the next step go into the triple whose own walk
        # finished a step ago, and the wave stalls on the matrix unit anyway,
        # so the ordering is free.
        v_ld4_l  v1, v7, s9,  0 
        v_ld4_l  v2, v8, s9,  0 
        v_ld4_l  v3, v7, s10, 0 
        s_waitcnt_l 0
        mma_i8   A0, v1, v3
        mma_i8   A1, v2, v3

        v_ld4_l  v4, v7, s9,  4 
        v_ld4_l  v5, v8, s9,  4 
        v_ld4_l  v6, v7, s10, 4 
        s_waitcnt_l 0
        mma_i8   A0, v4, v6
        mma_i8   A1, v5, v6

        v_ld4_l  v1, v7, s9,  8 
        v_ld4_l  v2, v8, s9,  8 
        v_ld4_l  v3, v7, s10, 8 
        s_waitcnt_l 0
        mma_i8   A0, v1, v3
        mma_i8   A1, v2, v3

        v_ld4_l  v4, v7, s9,  12
        v_ld4_l  v5, v8, s9,  12
        v_ld4_l  v6, v7, s10, 12
        s_waitcnt_l 0
        mma_i8   A0, v4, v6
        mma_i8   A1, v5, v6

        v_ld4_l  v1, v7, s9,  16
        v_ld4_l  v2, v8, s9,  16
        v_ld4_l  v3, v7, s10, 16
        s_waitcnt_l 0
        mma_i8   A0, v1, v3
        mma_i8   A1, v2, v3

        v_ld4_l  v4, v7, s9,  20
        v_ld4_l  v5, v8, s9,  20
        v_ld4_l  v6, v7, s10, 20
        s_waitcnt_l 0
        mma_i8   A0, v4, v6
        mma_i8   A1, v5, v6

        v_ld4_l  v1, v7, s9,  24
        v_ld4_l  v2, v8, s9,  24
        v_ld4_l  v3, v7, s10, 24
        s_waitcnt_l 0
        mma_i8   A0, v1, v3
        mma_i8   A1, v2, v3

        v_ld4_l  v4, v7, s9,  28
        v_ld4_l  v5, v8, s9,  28
        v_ld4_l  v6, v7, s10, 28
        s_waitcnt_l 0
        mma_i8   A0, v4, v6
        mma_i8   A1, v5, v6

        s_addi   s3,  s3,  32           # next k panel of A
        s_addi   s4,  s4,  32           # next k panel of Bt
        s_xori   s9,  s9,  4096
        s_xori   s10, s10, 4096
        s_xori   s11, s11, 4096
        s_waitcnt_l 0
        s_barrier
        s_addi   s0,  s0,  -32
        s_bnz_i  s0, kloop

# ================================================================= epilogue
        # lane n writes C[m_w + m][N0 + n_w + n] for m = 0..31, and the last
        # barrier of the loop has already made every wave's accumulators
        # final, so no wait is needed here.
        s_shri   s14, s12, 1
        s_shli   s14, s14, 5            # m_w
        s_muli   s1,  s7,  4            # ldc = N*4
        s_mul    s14, s14, s1
        s_add    s14, s5,  s14          # &C[m_w][0]
        s_andi   s2,  s12, 1
        s_shli   s2,  s2,  4            # n_w
        s_shli   s0,  s13, 5            # N0 = 32 * group_id_x
        s_add    s2,  s2,  s0
        s_shli   s2,  s2,  2
        s_add    s14, s14, s2           # &C[m_w][N0 + n_w]
        # lane*4 goes in the staging quad, not in v10 as section 5.2 has it:
        # v10 is "free after the last fill" only for a kernel that runs one
        # workgroup and stops.  This one comes back for the next one.
        v_shli   v12, v0,  2            # lane*4

        acc_rd   v1, 0
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 1
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 2
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 3
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 4
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 5
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 6
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 7
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 8
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 9
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 10
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 11
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 12
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 13
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 14
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 15
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 16
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 17
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 18
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 19
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 20
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 21
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 22
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 23
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 24
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 25
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 26
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 27
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 28
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 29
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 30
        v_st4_g  v1, v12, s14, 0
        s_add    s14, s14, s1
        acc_rd   v1, 31
        v_st4_g  v1, v12, s14, 0

# ================================================== next workgroup of the grid
        # A is the same 64 rows for every workgroup, so its pointer rewinds to
        # where the pass found it; Bt moves on by 32 rows.  Both advanced by
        # K + 32 during the pass: 32 bytes for each of the K/32 panels the k
        # loop staged, plus 32 for the one the prologue staged.
        s_addi   s13, s13, 1
        s_sub    s3,  s3,  s6
        s_addi   s3,  s3,  -32
        s_muli   s14, s6,  32
        s_addi   s14, s14, -96
        s_add    s4,  s4,  s14
        s_imm    s14, 2                 # N/32 workgroups in the grid
        s_sub    s14, s13, s14
        s_bnz_i  s14, gxpass

# ================================================================== counters
# Section 7.4: the kernel reads its own performance counters so that section
# 7.3's predictions can be falsified without an instrumentation harness.  The
# barrier first, so the numbers cover every wave and not just this one.
        s_waitcnt_l 0
        s_barrier
        s_rd_sys s0,  8                 # perf_cycles
        s_rd_sys s1,  9                 # perf_instrs, this wave
        s_rd_sys s2,  10                # perf_mma_busy, the whole unit
        s_rd_sys s3,  11                # perf_gmem_bytes
        s_rd_sys s4,  13                # perf_gmem_trans
        s_endpgm

# ================================================================= fill_tile
# Stage one 64x32 A panel and one 32x32 Bt panel into the LDS buffer at s11.
# Each wave moves 16 A rows and 8 Bt rows.  One v_ld16_g is 16 lanes x 16 B =
# 256 B = eight whole 32 byte panel rows, so A is two accesses and Bt is one.
fill_tile:
        s_mov    s1, s3
        v_ld16_g v12, v9, s1, 0         # A rows 0..7
        s_add    s1, s1, s8             # += 8*K
        s_waitcnt_g 0
        v_st4_l  v12, v10, s11, 0
        v_st4_l  v13, v10, s11, 4
        v_st4_l  v14, v10, s11, 8
        v_st4_l  v15, v10, s11, 12
        v_ld16_g v12, v9, s1, 0         # A rows 8..15
        s_addi   s11, s11, 288          # 8 rows * 36
        s_waitcnt_g 0
        v_st4_l  v12, v10, s11, 0
        v_st4_l  v13, v10, s11, 4
        v_st4_l  v14, v10, s11, 8
        v_st4_l  v15, v10, s11, 12
        s_addi   s11, s11, -288
        v_ld16_g v12, v9, s4, 0         # Bt rows 0..7: one access
        s_waitcnt_g 0
        v_st4_l  v12, v11, s11, 0
        v_st4_l  v13, v11, s11, 4
        v_st4_l  v14, v11, s11, 8
        v_st4_l  v15, v11, s11, 12
        s_b      s15
