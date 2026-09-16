# Loads and stores, section 3.3 and section 5.
#
# The registers check the loads and the +mexpect file checks the stores,
# which matters: a test that only reads its own stores back cannot see a load
# and a store that are wrong in the same direction - a byte lane swapped in
# both, say - because the two errors cancel.  So the store side is compared
# against the memory array itself, word for word, against numbers computed
# from the document.
#
# The data file holds 0x1234, 0xabcd, 0x00ff, 0x8000 at words 0 to 3, so the
# bytes of word 0 are 0x34 at address 0 and 0x12 at address 1.

movi r1, 0
ld   r2, r1, 0          # mem16[0]  = 0x1234
ld   r3, r1, 1          # mem16[2]  = 0xabcd
ld   r4, r1, 3          # mem16[6]  = 0x8000

ldb  r5, r1             # mem8[0] = 0x34, zero extended
movi r6, 1
ldb  r7, r6             # mem8[1] = 0x12, the high byte of word 0
movi r8, 3
ldb  r9, r8             # mem8[3] = 0xab, the high byte of word 1

# Stores, into words 8 and 10, which the data file never touched.
movi  r10, 0
movih r10, 0xbe
ori   r10, 0xef         # r10 = 0xbeef
movi  r11, 16           # byte address 16 is word 8
st    r10, r11, 0       # mem16[16] = 0xbeef
st    r10, r11, 2       # mem16[20] = 0xbeef, the displacement is halfwords

# ... and then overwrite word 8 one byte at a time, which is what proves the
# byte enables select a lane instead of writing the whole word.
movi r12, 0x5a
stb  r12, r11           # mem8[16] = 0x5a, the low byte of word 8
movi r13, 17
movi r14, 0x77
stb  r14, r13           # mem8[17] = 0x77, the high byte: word 8 is now 0x775a

# A halfword access ignores bit 0 of the address, section 5, so 21 reads the
# word at 20.  This load is also the last instruction before the halt: its
# value arrives on the halting edge and still has to be written back.
# A store whose value is the load immediately before it.  The M format read
# side needs the forwarding path too, not only the ALU's: without it this
# would store whatever r6 held before, which is 1.
ld   r6, r1, 2          # mem16[4] = 0x00ff
st   r6, r11, 6         # mem16[28] = 0x00ff, which is word 14

movi r15, 21
ld   r0, r15, 0         # mem16[20] = 0xbeef

halt
