# A real kernel rather than a list of instructions: walk a counted array,
# add it up, store the result.
#
# What this reaches that the other tests do not is the load-use case.
# "ld r4, r1, 0" is followed immediately by "add r3, r4", and section 9 of
# docs/cpu_16_16_16_16.md says that is free: the load's value arrives on the
# edge that decodes the add, and the read side forwards it.  A core that
# forgot the forwarding path would add whatever r4 held on the previous
# iteration, which for this data means 28 instead of 36 - and the first
# iteration would add x.

      movi r1, 0
      ld   r2, r1, 0            # the count
      movi r3, 0                # the running sum
      addi r1, 2                # point at the first element

loop: cmpi r2, 0
      beq  done
      ld   r4, r1, 0
      add  r3, r4               # the load-use case, with no stall
      addi r1, 2
      addi r2, -1
      br   loop

done: movi r5, 32               # byte address 32 is word 16
      st   r3, r5, 0
      halt
