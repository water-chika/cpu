# Every instruction docs/cpu_16_16_16_16.md defines, encoded.
#
# The simulation tests run programs and look at registers, which pins what an
# instruction *does*.  This pins where its bits are: assemble the source,
# compare the words against cpu_16_16_16_16_encoding.expect16, and no field
# can move without someone noticing.
#
# The operands are chosen so that a field swapped with its neighbour cannot
# pass.  The R format instructions use rd=1, rs=2; the shift forms use rd=3,
# sh=5; the byte and min/max forms use rd=6, rs=7, so that an rs/rd swap
# changes the word every time.
#
# The last section reproduces section 10's worked encodings verbatim, so the
# table in the document and this file fail together or not at all.


# ---- section 3.1, R format, two registers
and    r1, r2
or     r1, r2
not    r1, r2
xor    r1, r2
add    r1, r2
adc    r1, r2
sub    r1, r2
sbb    r1, r2
neg    r1, r2
mul    r1, r2
div    r1, r2
mov    r1, r2
cmp    r1, r2
tst    r1, r2
shl    r1, r2
shr    r1, r2
sar    r1, r2
rol    r1, r2
ror    r1, r2

# ---- section 3.1, R format, the shift amount in the rs field
shli   r3, 5
shri   r3, 5
sari   r3, 5
roli   r3, 5
rori   r3, 5
shli   r3, 0
rori   r3, 15

# ---- section 3.1, bytes, sign extension, min and max
ldb    r6, r7
stb    r6, r7
sxb    r6, r7
min    r6, r7
max    r6, r7

# ---- section 3.1, the registers that are not read as data
jmpr   r9
callr  r9
rd_sys r4, 0
rd_sys r4, 1
rd_sys r4, 2
halt
nop
ret

# ---- section 3.2, the six immediate classes
movi   r3, 0
movi   r3, 127
movi   r3, -128
movih  r3, 255
addi   r10, 1
addi   r10, -128
cmpi   r0, 127
andi   r1, 255
ori    r2, 128

# ---- section 3.3, load and store with a displacement
ld     r1, r2, 0
ld     r1, r2, 15
st     r5, r6, 1
st     r15, r14, 13

# ---- section 3.4, all fifteen conditions, each reaching the same label
# Fifteen words from "top", so the displacement counts down 15, 14, ... 1.
top:
beq    bottom
bne    bottom
blo    bottom
bhs    bottom
bmi    bottom
bpl    bottom
bvs    bottom
bls    bottom
bge    bottom
blt    bottom
bgt    bottom
ble    bottom
bhi    bottom
bvc    bottom
br     bottom
bottom:

# ---- backwards, which is where the sign of disp8 shows
back:
br     back
beq    back

# ---- section 3.5, the long jumps
jmp    forward
call   forward
forward:
jmp    back
call   back

# ---- section 8, "la", which is movi then movih of a *byte* address
la     r4, forward
la     r5, top

# ---- section 10's worked encodings, in the order the table gives them
and    r1, r2
add    r15, r0
sub    r3, r4
mov    r7, r8
cmp    r1, r1
shli   r5, 3
sari   r2, 15
ldb    r6, r7
jmpr   r9
rd_sys r4, 1
halt
ret
movi   r3, 0x7f
movi   r3, -1
movih  r3, 0x12
addi   r10, -2
cmpi   r0, 10
andi   r1, 0xff
ori    r2, 0x80
ld     r1, r2, 3
st     r5, r6, 0
beq    here
here:
self:
bne    self
br     here2
here2:
jmp    here3
here3:
call    there
nop
there:
halt
