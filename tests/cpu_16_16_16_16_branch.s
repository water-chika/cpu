# All fifteen branch conditions of section 3.4, under three different flag
# states, each collected into a bit pattern.
#
# One taken branch proves almost nothing: a condition that is always taken
# passes any test that only ever expects it to be taken.  So each round walks
# the conditions from 0xe down to 0x0, shifting the accumulator left and
# setting bit 0 when the branch was taken, which leaves condition c in bit c
# of the accumulator.  A condition that is wrong in either direction changes
# the word.
#
# The three rounds are chosen so that no two conditions agree in all of them:
#
#   round A   5 - 5      Z=1 N=0 C=0 V=0   r2 = 0x66a9
#   round B   3 - 7      Z=0 N=1 C=1 V=0   r4 = 0x6a96
#   round C   0x8000 - 1 Z=0 N=0 C=0 V=1   r6 = 0x696a
#
# The expected words were computed from the section 3.4 table by hand; round
# C is the one that separates bge/blt/bgt/ble from bmi/bpl, because it is the
# only state where N and V disagree.
#
# The flags have to be re-established inside every step, because the shli and
# the ori that build the accumulator write Z and N themselves.

# ---- round a
movi r1, 5
movi r2, 0

shli r2, 1
cmpi r1, 5
br take_a_br
br   skip_a_br
take_a_br:
ori  r2, 1
skip_a_br:

shli r2, 1
cmpi r1, 5
ble take_a_ble
br   skip_a_ble
take_a_ble:
ori  r2, 1
skip_a_ble:

shli r2, 1
cmpi r1, 5
bgt take_a_bgt
br   skip_a_bgt
take_a_bgt:
ori  r2, 1
skip_a_bgt:

shli r2, 1
cmpi r1, 5
blt take_a_blt
br   skip_a_blt
take_a_blt:
ori  r2, 1
skip_a_blt:

shli r2, 1
cmpi r1, 5
bge take_a_bge
br   skip_a_bge
take_a_bge:
ori  r2, 1
skip_a_bge:

shli r2, 1
cmpi r1, 5
bls take_a_bls
br   skip_a_bls
take_a_bls:
ori  r2, 1
skip_a_bls:

shli r2, 1
cmpi r1, 5
bhi take_a_bhi
br   skip_a_bhi
take_a_bhi:
ori  r2, 1
skip_a_bhi:

shli r2, 1
cmpi r1, 5
bvc take_a_bvc
br   skip_a_bvc
take_a_bvc:
ori  r2, 1
skip_a_bvc:

shli r2, 1
cmpi r1, 5
bvs take_a_bvs
br   skip_a_bvs
take_a_bvs:
ori  r2, 1
skip_a_bvs:

shli r2, 1
cmpi r1, 5
bpl take_a_bpl
br   skip_a_bpl
take_a_bpl:
ori  r2, 1
skip_a_bpl:

shli r2, 1
cmpi r1, 5
bmi take_a_bmi
br   skip_a_bmi
take_a_bmi:
ori  r2, 1
skip_a_bmi:

shli r2, 1
cmpi r1, 5
bhs take_a_bhs
br   skip_a_bhs
take_a_bhs:
ori  r2, 1
skip_a_bhs:

shli r2, 1
cmpi r1, 5
blo take_a_blo
br   skip_a_blo
take_a_blo:
ori  r2, 1
skip_a_blo:

shli r2, 1
cmpi r1, 5
bne take_a_bne
br   skip_a_bne
take_a_bne:
ori  r2, 1
skip_a_bne:

shli r2, 1
cmpi r1, 5
beq take_a_beq
br   skip_a_beq
take_a_beq:
ori  r2, 1
skip_a_beq:

# ---- round b
movi r3, 3
movi r4, 0

shli r4, 1
cmpi r3, 7
br take_b_br
br   skip_b_br
take_b_br:
ori  r4, 1
skip_b_br:

shli r4, 1
cmpi r3, 7
ble take_b_ble
br   skip_b_ble
take_b_ble:
ori  r4, 1
skip_b_ble:

shli r4, 1
cmpi r3, 7
bgt take_b_bgt
br   skip_b_bgt
take_b_bgt:
ori  r4, 1
skip_b_bgt:

shli r4, 1
cmpi r3, 7
blt take_b_blt
br   skip_b_blt
take_b_blt:
ori  r4, 1
skip_b_blt:

shli r4, 1
cmpi r3, 7
bge take_b_bge
br   skip_b_bge
take_b_bge:
ori  r4, 1
skip_b_bge:

shli r4, 1
cmpi r3, 7
bls take_b_bls
br   skip_b_bls
take_b_bls:
ori  r4, 1
skip_b_bls:

shli r4, 1
cmpi r3, 7
bhi take_b_bhi
br   skip_b_bhi
take_b_bhi:
ori  r4, 1
skip_b_bhi:

shli r4, 1
cmpi r3, 7
bvc take_b_bvc
br   skip_b_bvc
take_b_bvc:
ori  r4, 1
skip_b_bvc:

shli r4, 1
cmpi r3, 7
bvs take_b_bvs
br   skip_b_bvs
take_b_bvs:
ori  r4, 1
skip_b_bvs:

shli r4, 1
cmpi r3, 7
bpl take_b_bpl
br   skip_b_bpl
take_b_bpl:
ori  r4, 1
skip_b_bpl:

shli r4, 1
cmpi r3, 7
bmi take_b_bmi
br   skip_b_bmi
take_b_bmi:
ori  r4, 1
skip_b_bmi:

shli r4, 1
cmpi r3, 7
bhs take_b_bhs
br   skip_b_bhs
take_b_bhs:
ori  r4, 1
skip_b_bhs:

shli r4, 1
cmpi r3, 7
blo take_b_blo
br   skip_b_blo
take_b_blo:
ori  r4, 1
skip_b_blo:

shli r4, 1
cmpi r3, 7
bne take_b_bne
br   skip_b_bne
take_b_bne:
ori  r4, 1
skip_b_bne:

shli r4, 1
cmpi r3, 7
beq take_b_beq
br   skip_b_beq
take_b_beq:
ori  r4, 1
skip_b_beq:

# ---- round c
movi r5, 0
movih r5, 0x80
movi r6, 0

shli r6, 1
cmpi r5, 1
br take_c_br
br   skip_c_br
take_c_br:
ori  r6, 1
skip_c_br:

shli r6, 1
cmpi r5, 1
ble take_c_ble
br   skip_c_ble
take_c_ble:
ori  r6, 1
skip_c_ble:

shli r6, 1
cmpi r5, 1
bgt take_c_bgt
br   skip_c_bgt
take_c_bgt:
ori  r6, 1
skip_c_bgt:

shli r6, 1
cmpi r5, 1
blt take_c_blt
br   skip_c_blt
take_c_blt:
ori  r6, 1
skip_c_blt:

shli r6, 1
cmpi r5, 1
bge take_c_bge
br   skip_c_bge
take_c_bge:
ori  r6, 1
skip_c_bge:

shli r6, 1
cmpi r5, 1
bls take_c_bls
br   skip_c_bls
take_c_bls:
ori  r6, 1
skip_c_bls:

shli r6, 1
cmpi r5, 1
bhi take_c_bhi
br   skip_c_bhi
take_c_bhi:
ori  r6, 1
skip_c_bhi:

shli r6, 1
cmpi r5, 1
bvc take_c_bvc
br   skip_c_bvc
take_c_bvc:
ori  r6, 1
skip_c_bvc:

shli r6, 1
cmpi r5, 1
bvs take_c_bvs
br   skip_c_bvs
take_c_bvs:
ori  r6, 1
skip_c_bvs:

shli r6, 1
cmpi r5, 1
bpl take_c_bpl
br   skip_c_bpl
take_c_bpl:
ori  r6, 1
skip_c_bpl:

shli r6, 1
cmpi r5, 1
bmi take_c_bmi
br   skip_c_bmi
take_c_bmi:
ori  r6, 1
skip_c_bmi:

shli r6, 1
cmpi r5, 1
bhs take_c_bhs
br   skip_c_bhs
take_c_bhs:
ori  r6, 1
skip_c_bhs:

shli r6, 1
cmpi r5, 1
blo take_c_blo
br   skip_c_blo
take_c_blo:
ori  r6, 1
skip_c_blo:

shli r6, 1
cmpi r5, 1
bne take_c_bne
br   skip_c_bne
take_c_bne:
ori  r6, 1
skip_c_bne:

shli r6, 1
cmpi r5, 1
beq take_c_beq
br   skip_c_beq
take_c_beq:
ori  r6, 1
skip_c_beq:

halt
