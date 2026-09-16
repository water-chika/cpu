# The cycle counter, section 7.
#
# "cycles" counts executed instructions and rd_sys returns its value before
# its own increment, so the n'th instruction of a program reads n-1.  That
# makes the expected values below a matter of counting the lines above them,
# which is the point: a counter that is off by one, or that counts while
# halted, or that counts the loader's cycles, cannot pass.

rd_sys r1, 0            # instruction 1, so 0
rd_sys r2, 0            # instruction 2, so 1
nop                     # 3
nop                     # 4
rd_sys r3, 0            # instruction 5, so 4
rd_sys r4, 1            # the high half, still 0

# A loop, so that the count is not something that could be read off by eye.
# The loop body is two instructions and runs ten times, the last of which
# falls through: instructions 8 to 27.
movi r5, 10
loop:
addi r5, -1
bne  loop

rd_sys r6, 0            # instruction 28, so 27

halt
