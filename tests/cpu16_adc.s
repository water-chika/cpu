# Check the carry flag through adc and sbb.
#
# It does a 16 bit add and then the matching 16 bit subtract, each as a pair
# of 8 bit operations, and finally checks that an add which does not carry
# really clears the flag.
#
#   0x01ff + 0x0001 = 0x0200        add then adc
#   0x0200 - 0x0001 = 0x01ff        sub then sbb
#
# Register use:
#   r0  0xff, the low byte of the first operand
#   r1  0x01, the high byte of the first operand, then the halt address
#   r2  0x01, the low byte of the second operand, then the carry clear check
#   r3  0x00, the high byte of the second operand
#   r4  low byte of the sum, r5 high byte
#   r6  low byte of the difference, r7 high byte

imm 7 5 r0
imm_s 7 2 r0
imm_s 3 0 r0
imm 1 0 r1
imm 1 0 r2
imm 0 0 r3

add r0 r2 r4        # 0xff + 0x01 = 0x00 carry out 1
adc r1 r3 r5        # 0x01 + 0x00 + 1 = 0x02

sub r4 r2 r6        # 0x00 - 0x01 = 0xff borrow out 1
sbb r5 r3 r7        # 0x02 - 0x00 - 1 = 0x01

add r3 r3 r3        # 0 + 0, which must clear the carry
adc r2 r3 r2        # so this is 1 + 0 + 0 = 1, not 2

la r1 halt

halt:
b 0 r1 0
