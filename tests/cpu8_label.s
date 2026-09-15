# Check that a label past the reach of a single 3 bit immediate still works.
#
# "far" sits at address 75 and "halt" at address 88, so both need all three
# 3 bit groups of the "la" expansion.  The program jumps to "far" over a long
# run of filler, which proves the assembler resolved the address rather than
# merely loading some constant: if the branch went anywhere else, r5 would
# hold 7 instead of 0.
#
# Register use:
#   r0  unused
#   r1  src1/dst1 scratch that "la" builds the address in
#   r2  a label address
#   r3  marker, 5 only if the jump landed on far
#   r5  stays 0 only if the skipped instructions really were skipped

set_src1_dst1 r1
la r2 far
set_b_target r2
b b

imm 7          # skipped, and a wrong branch target would run it
mov r5

condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler
condition_1 condition_1    # filler

far:
imm 5
mov r3
la r2 halt
set_b_target r2

halt:
b b
