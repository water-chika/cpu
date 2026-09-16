# gpu16 workgroup: docs/gpu_isa.md sections 3.2, 3.3 and 7.2, run with four
# waves.  Every wave runs this same program; they are told apart only by
# `s_rd_sys 0`, which is what section 3.3 means by a workgroup.
#
# Three things are under test here and none of them exists in a one wave
# machine, which is why this is the only test that passes +waves=4:
#
#   1. the LDS is *shared*.  Each wave writes its own slot and every wave
#      reads all four, so a private scratchpad per wave fails.
#   2. `s_barrier` really waits.  Wave 3 is sent round a long delay loop
#      before it writes its slot, so a wave that walks through the barrier
#      reads the poison value 0 out of slot 3 and gets 0x33 instead of 0x46.
#   3. global memory is shared too, and by the same barrier: wave 0 reads
#      back through `s_ld_g` a word that only wave 3 ever wrote.
#
# And one thing about issue: section 7.2's Model-A issues "one instruction
# per cycle per compute unit, round-robin over ready waves".  Round robin is
# not something a value can see - every schedule runs the same instructions -
# so the last section measures it instead.  With four waves ready, wave 0
# gets one cycle in four, so a sixteen instruction stretch takes it about 64
# cycles; a unit that let wave 0 run to completion first would take 16.
# s11 is 1 if wave 0's own stretch cost at least 32 cycles, which separates
# the two by a factor of two in either direction.
#
# The answers, all in wave 0's registers because those are the ones the
# testbench checks:
#
#   s0  = 0        this is wave 0
#   s10 = 0x46     0x10 + 0x11 + 0x12 + 0x13, the four LDS slots
#   s11 = 1        wave 0 was interleaved with the other three
#   s14 = 0x23     what wave 3 stored to global memory
#
# Exec is lane 0 only for the value sections.  One live lane makes every LDS
# access single-bank and every global access a single transaction, which
# keeps those sections about waves rather than about lanes.
#
# The two contention sections in the middle turn all sixteen lanes back on,
# because a port that is shared has to be shared under load before the
# sharing is visible.  Each of them is bounded by a barrier at each end, so
# the counter reads either side of it see the whole workgroup's traffic for
# that section and nothing else:
#
#   s8  = 64       LDS port cycles: 4 waves x a deliberate 16-way conflict
#   s15 = 64       transactions:    4 waves x 16 distinct 64-byte blocks
#   s2  = 256      bytes asked for: 4 waves x 16 lanes x 4 bytes
#
# The first two would read 16 if the port served all four waves in the same
# cycle, and 16 again if the counters had stayed per wave instead of per
# workgroup; s2 would read 64.  The factor of four is the whole claim: one
# port, one workgroup, shared - and section 4.3's "by this workgroup" taken
# literally for all three counters.

        s_imm       s1, 1
        s_wr_exec   s1                  # lane 0 only
        v_imm       v0, 0               # every access addresses base + 0

        s_rd_sys    s0, 0               # wave id, 0..3
        s_shli      s2, s0, 6           # this wave's LDS slot, 64 bytes apart
        s_imm       s3, 0x20
        s_add       s3, s3, s0          # 0x20 + wave_id, the global payload
        s_shli      s5, s0, 6
        s_imm       s4, 256
        s_add       s5, s5, s4          # this wave's global slot, 256 + 64*id

# ---- poison, then barrier A: every slot holds 0 before anyone trusts one
        v_imm       v1, 0
        v_st4_l     v1, v0, s2, 0
        s_waitcnt_l 0
        s_barrier

# ---- wave 3 takes the long way round
        s_imm       s6, 3
        s_sub       s6, s0, s6
        la          s7, write_slot
        s_bnz       s6, s7              # waves 0..2 skip the delay

        s_imm       s8, 60
delay:  s_addi      s8, s8, -1
        s_bnz_i     s8, delay

write_slot:
        s_imm       s9, 0x10
        s_add       s9, s9, s0          # 0x10 + wave_id
        v_writelane v1, s9, 0
        v_st4_l     v1, v0, s2, 0
        s_waitcnt_l 0

# ---- barrier B: the one under test
        s_barrier

# ---- every wave sums all four slots out of the shared LDS
        s_imm       s10, 0

        s_imm       s4, 0
        v_ld4_l     v2, v0, s4, 0
        s_waitcnt_l 0
        v_readlane  s9, v2, 0
        s_add       s10, s10, s9

        s_imm       s4, 64
        v_ld4_l     v2, v0, s4, 0
        s_waitcnt_l 0
        v_readlane  s9, v2, 0
        s_add       s10, s10, s9

        s_imm       s4, 128
        v_ld4_l     v2, v0, s4, 0
        s_waitcnt_l 0
        v_readlane  s9, v2, 0
        s_add       s10, s10, s9

        s_imm       s4, 192
        v_ld4_l     v2, v0, s4, 0
        s_waitcnt_l 0
        v_readlane  s9, v2, 0
        s_add       s10, s10, s9        # 0x46

# ---- the same argument through the global port
        v_writelane v3, s3, 0
        v_st4_g     v3, v0, s5, 0
        s_waitcnt_g 0
        s_barrier                       # barrier C: all four stores landed
        s_imm       s4, 448             # 256 + 64*3, wave 3's slot
        s_ld_g      s14, s4, 0
        s_waitcnt_g 0                   # 0x23

# ---- the LDS port under load, sections 3.2 and 3.1
#
# Sixteen lanes at a stride of 64 bytes all land in bank 0, so one wave's
# access costs 16 port cycles by section 3.2's rule.  Four waves do it at
# once into four separate 1 KiB regions, and the port is one port: 64.
        s_barrier                       # barrier D
        s_exec_all
        v_lane_id   v4
        v_shli      v4, v4, 6           # lane * 64: every lane in bank 0
        s_imm       s4, 1024
        s_mul       s4, s4, s0
        s_imm       s2, 4096
        s_add       s4, s4, s2          # 4096 + 1024*wave_id, 1 KiB per wave
        s_rd_sys    s6, 12
        v_st4_l     v1, v4, s4, 0
        s_waitcnt_l 0
        s_barrier                       # barrier E
        s_rd_sys    s7, 12
        s_sub       s8, s7, s6          # 64

# ---- the global port under load, sections 3.1 and 4.8
#
# Sixteen lanes at a stride of 64 bytes are sixteen distinct aligned blocks,
# which is section 4.8's worst case: 16 transactions, one per lane.  Four
# waves, four 1 KiB regions, one port: 64.
        s_imm       s4, 1024
        s_mul       s4, s4, s0          # 1024 * wave_id
        s_rd_sys    s6, 13
        s_rd_sys    s2, 11
        v_st4_g     v1, v4, s4, 0
        s_waitcnt_g 0
        s_barrier                       # barrier F
        s_rd_sys    s7, 13
        s_sub       s15, s7, s6         # 64
        s_rd_sys    s7, 11
        s_sub       s2, s7, s2          # 256

        s_wr_exec   s1                  # back to lane 0 only

# ---- round robin, measured
#
# Sixteen instructions from one `s_rd_sys` to the next - fifteen `s_nop` and
# the second read - executed by all four waves at once because barrier C left
# them in step.
        s_rd_sys    s12, 8
        s_nop
        s_nop
        s_nop
        s_nop
        s_nop
        s_nop
        s_nop
        s_nop
        s_nop
        s_nop
        s_nop
        s_nop
        s_nop
        s_nop
        s_nop
        s_rd_sys    s13, 8
        s_sub       s11, s13, s12       # about 64 shared, about 16 alone

        s_imm       s13, 32
        s_sub       s13, s11, s13
        s_imm       s11, 0
        la          s12, done
        s_blz       s13, s12            # under 32 cycles: wave 0 ran alone
        s_imm       s11, 1

done:   s_endpgm
