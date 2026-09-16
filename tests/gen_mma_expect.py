#!/usr/bin/env python3
"""Compute the gpu16 matrix tests' data file and expectation files.

docs/gpu_isa.md section 4.7 defines `mma_i8` as

    for m in 0..15:                      # accumulator index within the block
      for n in 0..15:                    # lane
        for k in 0..3:                   # the K step carried by one instruction
          a[16*blk + m] (lane n) += sext8(vA.byte[k] read from lane m)
                                  * sext8(vB.byte[k] read from lane n)

and `mma()` below is that loop transcribed, with `_z` being the same loop
starting from zero.  Everything this script writes - the operand data, the
sixteen accumulator rows each program ends with, and the cycle counts - is
computed from that definition and from the instruction listing of the program
in question.  **Nothing here is read back from the RTL.**  That is the whole
point of the file: an expectation captured from the simulator would agree with
the simulator by construction and could not falsify it, and the matrix unit is
the one part of this machine where a plausible-looking wrong answer - a
transposed tile, an off-by-one accumulator row, an A fragment read from the
wrong lane - is easy to produce and impossible to spot by eye.

usage:
    gen_mma_expect.py <tests-dir>

It rewrites tests/gpu_mma*.data32, tests/gpu_mma*.expect and
tests/gpu_mma*.vexpect in place, and is run by the `gpu_mma_expect` CTest,
which fails if the checked-in files are not what it produces.
"""

import sys
import os

W = 16          # lanes per wave, and the M and N extent of a tile
K = 4           # the K step one mma_i8 carries

# --------------------------------------------------------------- the model


def sext8(b):
    return b - 256 if b >= 128 else b


def u32(x):
    return x & 0xFFFFFFFF


def pack(bytes4):
    """Four int8 into one VGPR word, k = 0 in the low byte (little-endian)."""
    return u32(bytes4[0] & 0xFF | (bytes4[1] & 0xFF) << 8 |
               (bytes4[2] & 0xFF) << 16 | (bytes4[3] & 0xFF) << 24)


def byte(word, k):
    return sext8((word >> (8 * k)) & 0xFF)


def mma(acc, va, vb, exec_mask=0xFFFF, zero=False):
    """Section 4.7, transcribed.

    `acc` is the sixteen accumulators of one block, `acc[m][n]` being a[m] in
    lane n.  `va` and `vb` are the sixteen lanes of the two VGPR operands.
    Returns the updated block; lanes outside `exec_mask` keep what they had,
    but every row still participates - the A fragment is read across lanes and
    the cross lane read knows nothing about exec.
    """
    out = [row[:] for row in acc]
    for m in range(W):
        for n in range(W):
            if not (exec_mask >> n) & 1:
                continue
            d = 0 if zero else acc[m][n]
            for k in range(K):
                d += byte(va[m], k) * byte(vb[n], k)
            out[m][n] = d
    return out


def zeros():
    return [[0] * W for _ in range(W)]


# ----------------------------------------------------------- the operands
#
# Four int8 per lane, chosen so that no two rows and no two columns are equal,
# so that both signs appear, and - checked below - so that the asymmetric
# product really is asymmetric.  They are deliberately not a function of the
# lane index alone: a value that is the same in every lane proves nothing
# about a sixteen lane machine, and a value that is linear in the lane index
# makes too many wrong mappings look right.

def frag(seed, scale=1):
    out = []
    for i in range(W):
        row = []
        for k in range(K):
            v = (seed * 37 + i * 23 + k * 11 + i * k * 5) % 251 - 125
            row.append((v * scale) % 256)
        out.append(pack(row))
    return out


A1 = frag(1)
B1 = frag(2)
A2 = frag(3)
B2 = frag(4)
AS = frag(5)            # the symmetric case: B = A transposed, i.e. the
                        # same sixteen words, so `mma_i8_z A0, v0, v0`
AA = frag(6)            # the asymmetric case
BA = frag(7)

# Where each fragment sits in global memory, as a byte address.  One aligned
# 64-byte block each, so every load in these programs is one transaction.
REGIONS = [
    (0x000, A1, 'A1: the first K step of A'),
    (0x040, B1, 'B1: the first K step of B'),
    (0x080, A2, 'A2: the second K step of A'),
    (0x0c0, B2, 'B2: the second K step of B'),
    (0x100, AS, 'As: the symmetric case, used as both operands'),
    (0x140, AA, 'Aa: the asymmetric case, A'),
    (0x180, BA, 'Ba: the asymmetric case, B'),
]

# ------------------------------------------------------------ the programs
#
# One function per test program, each mirroring the instruction listing of the
# `.s` file beside it.  What they return is the sixteen VGPRs the program ends
# with, lane 0 first - `testgpu.v`'s +vexpect order - and the scalar registers
# it ends with.

DONT_CARE = None


def prog_gpu_mma():
    """tests/gpu_mma.s - acc_wr seeds C, two K steps accumulate onto it."""
    # acc_wr a[m] <- v13, where v13 = lane + 0x1000 + 16*m
    acc = [[0x1000 + 16 * m + n for n in range(W)] for m in range(W)]
    acc = mma(acc, A1, B1)
    acc = mma(acc, A2, B2)
    # acc_rd v[m] <- a[m]
    vregs = [[u32(acc[m][n]) for n in range(W)] for m in range(W)]
    sregs = [DONT_CARE] * W
    sregs[3], sregs[4], sregs[5], sregs[6] = 0x000, 0x040, 0x080, 0x0c0
    return sregs, vregs


def prog_gpu_mma_z():
    """tests/gpu_mma_z.s - acc_zero and mma_i8_z both erase the poison."""
    poison = [[0x5a5a + n for n in range(W)] for _ in range(W)]
    a0 = mma(zeros(), A1, B1)               # acc_zero A0, then mma_i8 A0
    a1 = mma(poison, A1, B1, zero=True)     # mma_i8_z A1 straight onto poison
    assert a0 == a1, 'the two ways of starting a tile must agree'
    # The program then subtracts the blocks row by row and ORs sixteen
    # v_cmp_nz masks into s8, so s8 is zero exactly when they agree.
    sregs = [DONT_CARE] * W
    sregs[8] = 0
    vregs = [[u32(a1[m][n]) for n in range(W)] for m in range(W)]
    return sregs, vregs


def prog_gpu_mma_sym():
    """tests/gpu_mma_sym.s - the symmetric product, D = As * As^T.

    `mma_i8_z A0, v0, v0` reads the same VGPR as both fragments, so
    B[k][n] = As[n][k] and the product is As * As^T, which is symmetric.  A
    matrix unit that swapped its two operands - read B across lanes and A per
    lane - would compute the transpose of the right answer and this test would
    still pass.  That is deliberate: it is the control for gpu_mma_map.
    """
    d = mma(zeros(), AS, AS, zero=True)
    for m in range(W):
        for n in range(W):
            assert d[m][n] == d[n][m], 'the control case must be symmetric'
    sregs = [DONT_CARE] * W
    sregs[3] = 0x100
    vregs = [[u32(d[m][n]) for n in range(W)] for m in range(W)]
    return sregs, vregs


def prog_gpu_mma_map():
    """tests/gpu_mma_map.s - the asymmetric product, which pins the mapping."""
    d = mma(zeros(), AA, BA, zero=True)
    off_diagonal = sum(1 for m in range(W) for n in range(W)
                       if m != n and d[m][n] != d[n][m])
    assert off_diagonal > 200, (
        'the asymmetric case must differ from its transpose nearly everywhere, '
        'otherwise a transposed matrix unit could still pass: %d of 240'
        % off_diagonal)
    # A second property, which is what makes this test bite on a unit that
    # reads the A fragment from the lane instead of from the row: no
    # accumulator row may equal any other, and no column may equal any other.
    rows = set(tuple(r) for r in d)
    cols = set(tuple(d[m][n] for m in range(W)) for n in range(W))
    assert len(rows) == W and len(cols) == W, 'rows and columns must be distinct'
    sregs = [DONT_CARE] * W
    sregs[3], sregs[4] = 0x140, 0x180
    vregs = [[u32(d[m][n]) for n in range(W)] for m in range(W)]
    return sregs, vregs


EXEC_MASK = 0x0F0F


def prog_gpu_mma_exec():
    """tests/gpu_mma_exec.s - section 4.7's sharp edge.

    "`vA` is read from all 16 lanes regardless of `exec`, but accumulators are
    updated only in lanes where `exec[n] = 1`."  So with exec = 0x0f0f the
    eight disabled lanes keep their poison, and the eight enabled ones hold a
    product every one of whose sixteen A rows - including the eight belonging
    to disabled lanes - contributed.
    """
    poison = [[0x6000 + 16 * m + n for n in range(W)] for m in range(W)]
    d = mma(poison, AA, BA, exec_mask=EXEC_MASK, zero=True)
    # The rows that only a disabled lane could have supplied must still be
    # there, and must not be zero: that is the half of the rule a unit which
    # masked the A read as well as the accumulator write would get wrong.
    for m in range(W):
        if not (EXEC_MASK >> m) & 1:
            assert any(d[m][n] != poison[m][n] for n in range(W)
                       if (EXEC_MASK >> n) & 1), (
                'accumulator row %d comes from a disabled lane and must still '
                'have been computed' % m)
    sregs = [DONT_CARE] * W
    sregs[7] = EXEC_MASK
    sregs[8] = 0xFFFF
    vregs = [[u32(d[m][n]) for n in range(W)] for m in range(W)]
    return sregs, vregs


# The timing test's numbers, and where each comes from.  Section 4.7: "the
# hardware is 64 int8 MACs wide (16 lanes x 4 k) and the instruction occupies
# the matrix unit for 16 cycles, one accumulator row per cycle", and section
# 7.2's Model-A: "one instruction issued per cycle", "`mma_i8`: 1 issue cycle,
# occupies the matrix unit for 16 cycles; a wave issuing a second `mma` stalls
# until the unit frees".
MMA_CYCLES = 16
MMA_COUNT = 8

# One wave, so every cycle the wave can use it is a cycle it gets.
#
#   acc_zero stretch: the `s_rd_sys` that reads the clock, then acc_zero's own
#   issue cycle, sixteen rows, the `acc_rd` that cannot issue until the last
#   row has landed, and the `s_rd_sys` that reports.  1 + 16 + 1 + 1 = 19.
ACC_ZERO_STRETCH = 1 + MMA_CYCLES + 1 + 1
#   mma stretch: the first `mma_i8`'s issue cycle, then eight instructions'
#   worth of matrix occupancy back to back at MMA_CYCLES each - the second
#   `mma_i8` issues on the last cycle of the first one's walk, which is what
#   "occupies the matrix unit for 16 cycles" means for throughput - and then
#   the same two trailing instructions.  1 + 8*16 + 1 + 1 = 131.
MMA_STRETCH = 1 + MMA_COUNT * MMA_CYCLES + 1 + 1


def prog_gpu_mma_perf():
    """tests/gpu_mma_perf.s - the cycle counts, which no value can see."""
    sregs = [DONT_CARE] * W
    sregs[4] = 0                        # perf_mma_busy before anything
    sregs[5] = 0                        # ... and after acc_zero: no MACs used
    sregs[10] = ACC_ZERO_STRETCH
    sregs[8] = MMA_STRETCH
    sregs[9] = MMA_COUNT * MMA_CYCLES   # perf_mma_busy afterwards
    return sregs, None


def prog_gpu_mma_wg():
    """tests/gpu_mma_wg.s - four waves queueing for one 64-MAC array."""
    sregs = [DONT_CARE] * W
    sregs[9] = 4 * MMA_COUNT * MMA_CYCLES       # perf_mma_busy, the workgroup's
    sregs[11] = 1                               # the stretch was >= 512 cycles
    return sregs, None


PROGRAMS = [
    ('gpu_mma', prog_gpu_mma),
    ('gpu_mma_z', prog_gpu_mma_z),
    ('gpu_mma_sym', prog_gpu_mma_sym),
    ('gpu_mma_map', prog_gpu_mma_map),
    ('gpu_mma_exec', prog_gpu_mma_exec),
    ('gpu_mma_perf', prog_gpu_mma_perf),
    ('gpu_mma_wg', prog_gpu_mma_wg),
]


# ------------------------------------------------------------- the writing


def write_data(path):
    words = [0] * 1024
    for base, f, _ in REGIONS:
        for i in range(W):
            words[base // 4 + i] = f[i]
    lines = [
        '// gpu16 matrix unit test data, used by every gpu_mma* test.',
        '//',
        '// Seven 64-byte regions, one aligned block each, holding the A and B',
        '// fragments of docs/gpu_isa.md section 4.7: four packed int8 per lane,',
        '// k = 0 in the low byte.  Word i of a region is the fragment lane i',
        '// reads - which for an A fragment is matrix row i, and for a B',
        '// fragment is matrix column i.',
        '//',
    ]
    for base, _, what in REGIONS:
        lines.append('//   0x%03x  %s' % (base, what))
    lines += [
        '//',
        '// Generated by tests/gen_mma_expect.py.  Do not edit by hand.',
    ]
    for row in range(0, 1024, 16):
        lines.append(' '.join('%08x' % words[row + i] for i in range(16)))
    write(path, lines)


def write_expect(path, name, sregs):
    lines = [
        '// %s.s, the sixteen scalar registers.  Generated by' % name,
        '// tests/gen_mma_expect.py from docs/gpu_isa.md section 4.7; not',
        '// captured from the RTL.  "xxxxxxxx" is "do not care".',
    ]
    for i, v in enumerate(sregs):
        if v is DONT_CARE:
            lines.append('xxxxxxxx    // s%d' % i)
        else:
            lines.append('%08x    // s%d = %d' % (u32(v), i, v))
    write(path, lines)


def write_vexpect(path, name, vregs):
    lines = [
        '// %s.s, all 256 VGPRs: sixteen lanes of v0, then sixteen of v1,' % name,
        '// and so on.  Each program ends by reading one accumulator block back',
        '// with sixteen `acc_rd`, so line m is accumulator a[m] and column n',
        '// is lane n - i.e. this is the 16 x 16 int32 tile C[m][n] of section',
        '// 2.3, written out as the register file holds it.',
        '//',
        '// Generated by tests/gen_mma_expect.py, which computes it from',
        '// section 4.7\'s definition of mma_i8.  Do not edit by hand.',
    ]
    for m, row in enumerate(vregs):
        lines.append(' '.join('%08x' % w for w in row) + ' // v%d = a[%d]' % (m, m))
    write(path, lines)


def write(path, lines):
    with open(path, 'w') as f:
        f.write('\n'.join(lines) + '\n')


def main():
    if len(sys.argv) != 2:
        sys.stderr.write('usage: %s <tests-dir>\n' % sys.argv[0])
        return 2
    d = sys.argv[1]
    write_data(os.path.join(d, 'gpu_mma.data32'))
    for name, fn in PROGRAMS:
        sregs, vregs = fn()
        write_expect(os.path.join(d, name + '.expect'), name, sregs)
        if vregs is not None:
            write_vexpect(os.path.join(d, name + '.vexpect'), name, vregs)
    return 0


if __name__ == '__main__':
    sys.exit(main())
