# The shifts and rotates that take their amount from a register, section
# 3.1.  The immediate forms are in cpu_16_16_16_16_alu.s.
#
# Three things here that the immediate forms cannot reach: that the amount
# is masked to four bits, so a shift by 17 is a shift by 1 and there is no
# "shift by the whole width" case to get wrong; that a rotate by zero is the
# identity rather than zero; and that sar is arithmetic where shr is not,
# which only shows on a value with bit 15 set.

movi  r1, 0
movih r1, 0x80          # r1 = 0x8000
movi  r2, 1

movi  r3, 0
movih r3, 0x12
ori   r3, 0x34          # r3 = 0x1234

movi  r5, 4

mov   r4, r3
shl   r4, r5            # 0x1234 << 4 = 0x2340

mov   r6, r3
shr   r6, r5            # 0x1234 >> 4 = 0x0123

mov   r7, r1
sar   r7, r2            # 0x8000 >> 1 arithmetic = 0xc000

mov   r8, r1
shr   r8, r2            # 0x8000 >> 1 logical = 0x4000

mov   r9, r3
rol   r9, r5            # 0x2340 | 0x0001 = 0x2341

mov   r10, r3
ror   r10, r5           # 0x0123 | 0x4000 = 0x4123

# The amount is masked to four bits, so 17 shifts by 1.
movi  r11, 17
mov   r12, r3
shl   r12, r11          # 0x1234 << 1 = 0x2468

# A rotate by zero is the identity, in both the register and the immediate
# form.  This is the case an implementation written as "value >> (16 - n)"
# gets wrong if 16 - 0 is not handled.
movi  r13, 0
mov   r14, r3
rol   r14, r13          # 0x1234

mov   r15, r3
rori  r15, 0            # 0x1234

halt
