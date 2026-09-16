# call, ret, callr and the link register, section 6.
#
# r15 is an ordinary register that call happens to write, so nesting is the
# caller's problem: f2 saves its own link before calling f4 and restores it
# before returning, which is the whole calling convention this machine has.
#
# The link value is checked without writing an address down: after the
# callr, "la r7, ret3" must produce exactly what call left in r15, so the
# subtraction is zero.  r5 and r6 hold addresses, which depend on where the
# program was assembled, so they are "do not care" in the expectation.

      movi  r1, 0

      call  f1                  # r1 += 10
      addi  r1, 1               # r1 += 1
      call  f2                  # r1 += 100, and f2 calls f4 for another 5

      la    r5, f3
      callr r5                  # r1 += 20
ret3: la    r7, ret3
      sub   r7, r15             # zero if the link was the return address

      halt

f1:   addi  r1, 10
      ret

f2:   mov   r6, r15             # nesting: keep our own return address
      addi  r1, 100
      call  f4
      mov   r15, r6
      ret

f4:   addi  r1, 5
      ret

f3:   addi  r1, 20
      ret
