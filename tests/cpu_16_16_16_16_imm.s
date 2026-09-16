# The immediate classes of section 3.2 and the "la" pseudo instruction of
# section 8.
#
# "la" is two words carrying a *byte* address, and this checks it twice over
# without ever writing an absolute address down: the distance between two
# labels one instruction apart must be exactly 2, and jumping to the address
# it produced must land where the label is.

movi  r1, 0x7f          # the largest positive imm8
movi  r2, -128          # the most negative one
movi  r3, 255           # movi sign extends, so 255 and -1 are one encoding

movi  r4, 0
movih r4, 0xab          # r4 = 0xab00, the low byte untouched

movi  r5, 0x34
movih r5, 0x12          # r5 = 0x1234, both halves placed

movi  r6, 10
addi  r6, -3            # subi does not exist: addi with a negative one is it

movi  r7, 0
movih r7, 0xff
ori   r7, 0x0f          # ori zero extends: 0xff0f
andi  r7, 0x0f          # andi zero extends: 0x000f

# andi and ori zero extend, which only shows when bit 7 of the immediate is
# set: sign extension would make these 0xff80 instead of 0x0080.
movi  r12, 0
movih r12, 0xff
ori   r12, 0xff         # 0xffff
andi  r12, 0x80         # 0xffff & 0x0080 = 0x0080

movi  r13, 0
ori   r13, 0x80         # 0x0000 | 0x0080 = 0x0080

la    r8, dest
la    r9, dest2
sub   r9, r8            # dest2 is one instruction later, so exactly 2 bytes

jmpr  r8                # ... and the address really is dest
movi  r10, 0xee         # never executed
dest:
movi  r10, 0x11
dest2:
movi  r11, 0x22

halt
