# Multiply, divide, min, max, sign extension, and the carry and borrow
# chains that adc and sbb exist for.  Section 3.1 and section 4.
#
# The two multi word chains are the point of the file: section 4 says C is
# written by add/adc/sub/sbb and by nothing else, so a movi may sit between
# the two halves of a chain without disturbing it, and both chains here do
# exactly that.

movi r1, 100            # 0x0064
movi r2, 7

mov  r3, r1
mul  r3, r2             # 700 = 0x02bc

mov  r4, r1
div  r4, r2             # 100 / 7 = 14, unsigned

movi r5, 5
movi r6, 0
div  r5, r6             # division by zero gives 0xffff

movi r7, -3             # 0xfffd
movi r8, 2

mov  r9, r7
min  r9, r8             # signed: -3

mov  r10, r7
max  r10, r8            # signed: 2

movi r11, 0x9c          # movi sign extends too: 0xff9c
sxb  r12, r11           # sign extend the low byte: 0xff9c

# The carry chain.  0xffff + 1 is zero with a carry out, and the movi
# between the add and the adc does not touch C.
movi r13, -1
movi r14, 1
add  r13, r14           # 0x0000, C = 1
movi r14, 0
adc  r14, r14           # 0 + 0 + 1 = 1

# The borrow chain.  0 - 1 borrows, and 5 - 5 - 1 is -1.
movi r0, 0
movi r15, 1
sub  r0, r15            # 0xffff, C = 1 (a borrow)
movi r15, 5
sbb  r15, r15           # 5 - 5 - 1 = 0xffff

halt
