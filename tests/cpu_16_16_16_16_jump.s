# The unconditional jump of section 3.5, class 0xd, which is the one control
# flow instruction the other tests do not reach: the branch test uses the
# eight bit "br", the call test uses class 0xe, and the immediate test uses
# jmpr.
#
# The four blocks run out of order - a, c, b, d - so a jump that went to the
# following instruction instead of to its label would produce 1, 2, 4, 8 in
# address order and the same total.  The powers of two are what stops that:
# each block adds a different bit, and skipping or repeating any of them
# changes r1.

      movi r1, 0
      jmp  a
      movi r1, 0xee     # never executed
a:    addi r1, 1
      jmp  c
b:    addi r1, 4
      jmp  d
c:    addi r1, 2
      jmp  b            # backwards, where the sign of disp12 shows
d:    addi r1, 8
      halt
