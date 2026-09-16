# The logic instructions and the shifts and rotates with an immediate
# amount, from docs/cpu_16_16_16_16.md section 3.1.
#
# Every expected value in cpu_16_16_16_16_alu.expect was computed from that
# table by hand and none of it was read back from the simulator.  The two
# operands are 0xf0f0 and 0x0ff0, which share some bits and differ in others
# in every nibble, so and, or and xor all produce different words - a swap of
# two of them cannot pass.

# Build the operands.  movi sign extends, so the high half has to come from
# movih, which is the whole reason movih exists.
movi  r1, 0
movih r1, 0xf0
ori   r1, 0xf0          # r1 = 0xf0f0
movi  r2, 0xf0          # sign extended: 0xfff0
movih r2, 0x0f          # r2 = 0x0ff0

mov   r3, r1
and   r3, r2            # 0xf0f0 & 0x0ff0 = 0x00f0

mov   r4, r1
or    r4, r2            # 0xf0f0 | 0x0ff0 = 0xfff0

mov   r5, r1
xor   r5, r2            # 0xf0f0 ^ 0x0ff0 = 0xff00

not   r6, r1            # ~0xf0f0 = 0x0f0f

mov   r7, r1
add   r7, r2            # 0xf0f0 + 0x0ff0 = 0x100e0, kept: 0x00e0

mov   r8, r1
sub   r8, r2            # 0xf0f0 - 0x0ff0 = 0xe100

neg   r9, r2            # -0x0ff0 = 0xf010

mov   r10, r2
shli  r10, 4            # 0x0ff0 << 4 = 0xff00

mov   r11, r1
shri  r11, 4            # 0xf0f0 >> 4 = 0x0f0f, logical

mov   r12, r1
sari  r12, 4            # 0xf0f0 >> 4 = 0xff0f, arithmetic

mov   r13, r1
roli  r13, 4            # 0x0f00 | 0x000f = 0x0f0f

mov   r14, r2
rori  r14, 4            # 0x00ff | 0x0000 = 0x00ff

halt
