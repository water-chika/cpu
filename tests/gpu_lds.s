# gpu16 LDS, the value half: docs/gpu_isa.md sections 3.2 and 4.9.
#
# Section 4.9 is four instructions - v_ld_l, v_ld4_l, v_st_l, v_st4_l - with
# the same operand shape as section 4.8's per lane global accesses, so what
# is new here is not the addressing but what sits behind it: sixteen banks of
# 4 bytes, 8 KiB in total, with the bank taken from bits 5:2 of the address.
#
# Nothing initialises the LDS, which is the point: unlike global memory there
# is no data file to load, so every word this program reads is a word it
# wrote.  That is also section 3.3's rule about visibility, exercised the only
# way a single wave can exercise it - `s_waitcnt_l` between a write and the
# read that depends on it.
#
# What the five sections below check:
#
#   1. a 4 byte round trip through the banks,
#   2. a 1 byte round trip, sixteen lanes into sixteen *consecutive* bytes,
#      which is four lanes to a bank word and therefore a test that a byte
#      write does not carry the other three bytes with it,
#   3. the same sixteen bytes read back as four words, which is where a
#      clobbered neighbour byte would show, under a mask that also checks a
#      masked load leaves the disabled lanes' registers alone,
#   4. a masked store leaves the disabled lanes' LDS alone,
#   5. the last sixteen words of the 8 KiB are addressable - row 127, the
#      top of section 3.2's scratchpad,
#   6. a store whose lane number is *not* its bank number lands in the right
#      bank: section 3.2's own padded 36 byte stride, where lane l writes
#      bank (9l) & 15,
#   7. and, after all six regions have been written, region 1 still reads
#      back what it was given - i.e. the 8 KiB really is 2048 distinct words
#      and not a smaller array that aliases.

v_lane_id   v0                  # v0 = lane
v_shli      v1, v0, 2           # v1 = lane * 4
s_imm       s3, 0               # region 1: the bottom of the LDS
s_imm       s4, 1024            # region 2: the byte region
s_imm       s5, 2048            # region 3: the masked store
s_imm       s6, 0x00ff          # lanes 0..7
s_imm       s9, 0x000f          # lanes 0..3
s_imm       s10, 8128           # region 4: the last sixteen words
s_imm       s8, 4096            # region 5: the padded tile row
s_imm       s11, 36             # section 3.2's conflict-free row stride
v_mul_s     v11, v0, s11        # v11 = lane * 36
s_rd_exec   s7                  # 0xffff, to restore with

# ---- 1. sixteen distinct words, one per bank, out and back
v_imm       v2, 0x0100
v_add       v2, v2, v0          # v2 = 0x100 + lane
v_st4_l     v2, v1, s3, 0
s_waitcnt_l 0
v_ld4_l     v3, v1, s3, 0
s_waitcnt_l 0                   # v3 must equal v2 in every lane

# ---- 2. one byte per lane into sixteen consecutive bytes
#
# Four lanes share each bank word here, so a v_st_l that wrote its whole word
# would leave each word holding one lane's value in all four bytes instead of
# four lanes' values in four bytes.  Section 3 below is what sees it.
v_imm       v4, 0x00a0
v_add       v4, v4, v0          # v4 = 0xa0 + lane
v_st_l      v4, v0, s4, 0       # address 1024 + lane
s_waitcnt_l 0
v_ld_l      v5, v0, s4, 0
s_waitcnt_l 0                   # v5 must equal v4, zero extended

# ---- 3. those sixteen bytes as four words, lanes 0..3 only
#
# Little-endian, so lane 0 reads 0xa3a2a1a0.  The twelve lanes the mask
# switches off must keep the poison they were given, which is the mirror half
# of section 1.2's exec rule.
v_imm       v6, 0x5555
s_wr_exec   s9
v_ld4_l     v6, v1, s4, 0       # words at 1024 + 4*lane
s_waitcnt_l 0
s_wr_exec   s7

# ---- 4. a masked store must leave the disabled lanes' LDS alone
v_imm       v7, 0x5555
v_st4_l     v7, v1, s5, 0       # background, all sixteen lanes
s_waitcnt_l 0
v_imm       v8, 0x1234
s_wr_exec   s6
v_st4_l     v8, v1, s5, 0       # only lanes 0..7 may write
s_waitcnt_l 0
s_wr_exec   s7
v_ld4_l     v9, v1, s5, 0       # lanes 8..15 must still read 0x5555
s_waitcnt_l 0

# ---- 5. the top of the 8 KiB, row 127
v_st4_l     v2, v1, s10, 0
s_waitcnt_l 0
v_ld4_l     v10, v1, s10, 0
s_waitcnt_l 0                   # v10 must equal v2

# ---- 6. a row stride of 36, where lane l writes bank (9l) & 15
#
# Every other access in this program gives lane l bank l, so a store that
# routed its data by lane number instead of by bank number would be right by
# accident.  Here the two disagree for fifteen of the sixteen lanes.
v_st4_l     v2, v11, s8, 0
s_waitcnt_l 0
v_ld4_l     v12, v11, s8, 0
s_waitcnt_l 0                   # v12 must equal v2

# ---- 7. region 1, read again now that five other regions have been written
#
# 8 KiB is 2048 words and every address in it is its own word.  An LDS that
# decoded fewer address bits than that would alias one of the regions above
# onto this one - the byte region at 1024 is the nearest - and this read is
# where it would show.
v_ld4_l     v13, v1, s3, 0
s_waitcnt_l 0                   # v13 must still equal v2

s_endpgm
