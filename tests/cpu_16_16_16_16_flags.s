# Which instruction writes which flag, section 4, read back through
# "rd_sys rd, 2" - which returns {12'b0, V, C, N, Z}, section 7.
#
# The interesting half of this file is what does *not* change: section 4 says
# C and V are written by add, adc, sub, sbb, neg, addi, cmp and cmpi and by
# nothing else, and that mov and movi write no flag at all.  So the andi, the
# tst and the mov below are each followed by a read that must still show the
# C left behind by an addi several instructions earlier.

movi r1, 5

cmpi r1, 5              # 0, so Z=1 N=0 C=0 V=0
rd_sys r2, 2            # 0b0001

cmpi r1, 6              # 0xffff with a borrow: Z=0 N=1 C=1 V=0
rd_sys r3, 2            # 0b0110

cmpi r1, 4              # 1: Z=0 N=0 C=0 V=0
rd_sys r4, 2            # 0b0000

# Signed overflow: 0x8000 - 1 is 0x7fff, which is positive, so V is set and
# N is not - the case bge and blt exist for.
movi  r5, 0
movih r5, 0x80          # r5 = 0x8000
cmpi  r5, 1             # Z=0 N=0 C=0 V=1
rd_sys r6, 2            # 0b1000

# A carry out of an add, which is not an overflow: 0xffff + 1.
movi r7, -1
addi r7, 1              # 0x0000: Z=1 N=0 C=1 V=0
rd_sys r8, 2            # 0b0101

# andi writes Z and N; C is still the one the addi left.
movi r9, 0
andi r9, 0xff           # 0: Z=1 N=0, C still 1
rd_sys r10, 2           # 0b0101

# tst writes Z and N and no register.
movi  r11, 0
movih r11, 0x80
mov   r12, r11
tst   r11, r12          # 0x8000: Z=0 N=1, C still 1
rd_sys r13, 2           # 0b0110

# mov writes nothing at all, so the read below must still be 0b0110.
movi r14, 0
mov  r14, r11
rd_sys r15, 2           # 0b0110

halt
