# Check that a label past the reach of a single 3 bit immediate still works.
#
# "far" sits at address 75 and "halt" at address 79, so both need all three
# 3 bit groups of the "la" expansion.  The program jumps to "far" over a long
# run of filler, which proves the assembler resolved the address rather than
# merely loading some constant: if the branch went anywhere else, r3 would
# hold 7 instead of 5.
#
# Register use:
#   r1  address of far
#   r3  marker, 5 only if the jump landed on far
#   r7  address of the halt branch

imm 0 0 r3
la r1 far
b 0 r1 0

imm 7 0 r3     # skipped, and a wrong branch target would run it

mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler
mov r0 0 r0    # filler

far:
imm 5 0 r3
la r7 halt

halt:
b 0 r7 0
