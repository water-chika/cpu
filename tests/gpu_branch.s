# gpu16 scalar unit: section 4.4 control flow, every form the scalar-only
# core implements.  The two exec-mask branches (0x29, 0x2a) are deliberately
# absent - there is no exec mask yet.
#
# Every target here is a label, which is what makes this a test of the
# assembler as well as of the core: the `_i` forms resolve to a word offset
# from PC_next, `s_imm` to a plain word address, and `la` to the same address
# through one s_addpc.

        s_imm   s3, 5                   # counter
        s_imm   s4, 0                   # accumulator

loop:   s_add   s4, s4, s3
        s_addi  s3, s3, -1
        s_bnz_i s3, loop                # five passes, s4 = 15
        s_bz_i  s3, counted             # taken, the counter reached zero

        s_imm   s5, 0xdead              # skipped
        s_imm   s6, 0xbeef              # skipped

counted:
        s_imm   s5, 1
        s_imm   s6, -7
        s_imm   s7, negative            # a branch target as a word address
        s_blz   s6, s7                  # taken, s6 < 0
        s_imm   s8, 0xdead              # skipped

negative:
        s_imm   s8, 2
        s_bgz   s6, s7                  # not taken, s6 < 0
        s_bz    s6, s7                  # not taken, s6 != 0
        la      s10, call_site          # the same address, through s_addpc
        s_bnz   s5, s10                 # taken, s5 != 0
        s_imm   s11, 0xdead             # skipped

call_site:
        s_call  s12, subroutine         # s12 = the next word
        s_imm   s13, 7                  # the call returns here
        s_endpgm

subroutine:
        s_imm   s15, 0x42
        s_b     s12                     # return through the link register
