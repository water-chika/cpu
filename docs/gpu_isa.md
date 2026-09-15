# Water's GPU - a SIMT sibling of cpu16

This is a *specification only*.  No RTL, no assembler and no compiler exists
for it yet.  Everything here is written so that it can be implemented later
against the existing repo conventions: Harvard architecture, a separate
program and data memory, an opcode field followed by fixed-width argument
fields, and the same table style the README uses for cpu8 and cpu16.

The machine is called **gpu16**: 16 lanes, 16 scalar registers, 16 vector
registers.

The whole design is driven by one workload: **tiled integer GEMM**,
`C[M][N] += A[M][K] * Bt[N][K]` with `int8` inputs, `int32` accumulation and
`B` supplied pre-transposed.  Every choice below is justified by the kernel in
section 5, and section 7 measures the result against a scalar cpu16 baseline.

**Revision 4** adds section 8, which answers the reviewer's follow-up
question - *should the instruction word be enlarged to carry 5-bit register
fields and a 32-entry VGPR file?* - by costing three options against the
section 7 numbers.  The answer is **no**, and the reason is that checking the
premise against section 7.3 shrinks it: the 32-register argument was worth
5.5% on the least important of six benchmarks and exactly zero on GEMM.  The
recommendation is to take the 5-bit fields **for free** by absorbing the
`Arg3` field that only two instructions use, implement 16 registers anyway,
and fix the kernel problem with a dead bit in `v_ld16_g`'s `Mod` field.  That
section also corrects an omission in section 7.5's area table, which never
accounted for program memory.  Section 8 is an evaluation and a
recommendation; **it does not change the encoding in sections 4.1 to 4.13**,
which still describe the 32-bit 8/4/4/4/4/8 word as specified.

**Revision 3.**  The first draft ended with six open questions (section 6.3).
**All six have since been decided** and folded in; this revision is the
result:

* `B` pre-transposed is a **precondition**, not an option (5.6).
* Wave width is **16 for the first implementation**, with the cost of a later
  widening spelled out (1.1).
* **`v_ld16_g` and `v_st16_g` were added** at 0x86/0x87 (4.8), the GEMM fill
  and the memory-bound benchmark were rewritten around them, and a dedicated
  correctness test plus an A/B performance control were added (7.4).
* **32 accumulators per lane** is confirmed (2.3).
* The accumulator file's **16-lane 32-bit read-modify-write per cycle** is
  promoted from the document's least-confident assumption to **architectural
  requirement A1** (2.3), with the consequences of failing it recorded
  explicitly (6.2).
* The scalar unit **is a widened `cpu16.v`** (4.13).  The scalar opcode map is
  consequently realigned onto cpu16's numbering, holes and all (4.3), and the
  five branch opcodes turned out to already match exactly.
* **`s_waitcnt` is split** into `s_waitcnt_g` and `s_waitcnt_l` (4.10), which
  costs the GEMM kernel zero instructions and removes an encoding in which
  "do not care" and "wait for 15" were indistinguishable.

No questions remain open.  What remains is measurement: section 7.4 exists to
falsify section 7.3, and section 6.2 ranks what is most likely to break
first.

## Contents

1. [Execution model](#1-execution-model)
2. [Register file](#2-register-file)
3. [Memory model](#3-memory-model)
4. [Instruction set and encoding](#4-instruction-set-and-encoding)
5. [A worked tiled GEMM kernel](#5-a-worked-tiled-gemm-kernel)
6. [Deliberate omissions and low-confidence areas](#6-deliberate-omissions-and-low-confidence-areas)
7. [Benchmark and evaluation plan](#7-benchmark-and-evaluation-plan)
8. [Revision 4: should the instruction word grow to 32 registers?](#8-revision-4-should-the-instruction-word-grow-to-32-registers)

---

## 1. Execution model

### 1.1 Lanes and wavefronts

The unit of execution is a **wavefront** (wave) of **W = 16 lanes**.  One
instruction stream drives all 16 lanes: a single program counter, a single
instruction fetch, 16 copies of the datapath.  This is SIMT, not SIMD, in the
sense that lanes are *addressed individually* by the exec mask and can hold
per-lane addresses, but there is exactly one PC.

`W = 16` was chosen because:

* the accumulator layout wants `W` to be the N-extent of the output tile, and
  16 is the largest power of two whose `W x W` `int32` accumulator block
  (16 x 16 x 4 B = 1 KiB) is still plausible on the kind of device this
  project can reach (section 7.5);
* a 16-bit mask is exactly one lane bit per bit, so an exec mask fits in the
  low half of one scalar register with no packing games;
* the matrix unit walks one accumulator row per cycle, so the cross-lane read
  of the A operand (section 4.7) degenerates to a 16:1 multiplexer rather
  than a 16x16 crossbar.

`W = 16` is settled **for the first implementation** (section 6.3, decision
2), not settled forever.  A later 32-lane revision is a coherent extension of
everything here, with one specific casualty: at `W = 32` the exec mask no
longer fits in half a scalar register, and the next section's most convenient
property - that masks *are* ordinary SGPRs and every scalar bitwise
instruction is also a mask instruction - stops being free.  Anyone widening
this machine should treat that, not the datapath, as the expensive part.

A **workgroup** is 4 waves (64 lanes) that share one scratchpad and can
synchronise with `s_barrier`.  Up to 4 waves are resident on the compute unit
at once; the hardware issues one instruction per cycle, round-robin over
waves that are ready.  Multi-wave residency is not a luxury here - section
7.2 shows the matrix unit only reaches high utilisation because one wave's
address arithmetic overlaps another wave's `mma`.

### 1.2 The exec mask

State: one 16-bit `exec` register.  Bit *l* enables lane *l*.

* Vector instructions (`v_*`) write a lane's registers only where `exec[l] = 1`.
  Lanes with `exec[l] = 0` still *read* operands (so cross-lane reads are
  well defined) but discard their result.
* Scalar instructions (`s_*`) always execute; they are per-wave, not per-lane.
* Memory instructions issue a transaction only for enabled lanes.
* `exec = 0` is legal.  Every vector instruction becomes a no-op and the wave
  continues to burn issue slots, which is why `s_cbr_execz` exists.

At wave launch `exec = 0xFFFF`.

### 1.3 Divergence and reconvergence

There is **no hardware reconvergence stack** and **no per-lane PC**.
Reconvergence is software-managed by saving and restoring `exec` in a scalar
register, in the same spirit as the rest of the machine: the ISA provides the
primitive, the program provides the policy.

The primitives are:

* `v_cmp_nz / v_cmp_z / v_cmp_lz / v_cmp_gz sdst, vsrc` - compare a lane value
  against zero (exactly the four conditions cpu16's branches already use) and
  write a 16-bit lane mask into `sdst`, ANDed with the current `exec`.
* `s_and_saveexec sdst, ssrc` - `sdst = exec; exec = exec & ssrc`.
* `s_xor_saveexec`, `s_or_saveexec` - same shape, other operators.
* `s_wr_exec ssrc` / `s_rd_exec sdst` - unconditional move.
* `s_cbr_execz label` / `s_cbr_execnz label` - branch on `exec` being all-zero.

A structured if/else is then:

```
        v_cmp_gz  s4, v1          # s4 = lanes where v1 > 0
        s_and_saveexec s5, s4     # s5 = old exec; exec &= s4
        s_cbr_execz  else_part    # nobody took the 'then' side
        ...                       # 'then' body
else_part:
        s_xor     s4, s5, s4      # lanes of old exec not in the 'then' set
        s_wr_exec s4
        s_cbr_execz endif
        ...                       # 'else' body
endif:
        s_wr_exec s5              # reconverge: restore the entry mask
```

A divergent *loop* accumulates an "still active" mask instead:

```
loop:   ...body...
        v_cmp_gz  s4, v6          # lanes that must keep going
        s_wr_exec s4
        s_cbr_execnz loop
        s_wr_exec s5              # reconverge
```

Uniform (wave-invariant) control flow does not touch `exec` at all and uses
the scalar branches `s_b / s_bz / s_bnz / s_blz / s_bgz`, which are the cpu16
branches with a wider target.

Cost of divergence is exactly what you would expect from one PC: a wave runs
for the *maximum* trip count over its 16 lanes.  Section 7.1's `escape` kernel
exists to put a number on that.

### 1.4 Hazards, latency and stalls

cpu16 handles memory latency with an ad-hoc `stall` flag.  gpu16 splits the
two cases explicitly, because a GPU cannot afford to stall on every load:

* **Register hazards are interlocked.**  ALU and matrix results are
  scoreboarded; a dependent instruction stalls the wave until the producer
  retires.  In particular `acc_rd` after `mma_i8` is safe with no manual wait.
* **Memory results are not interlocked.**  `v_ld*`, `s_ld_g` and the stores
  are fire-and-forget; a per-wave counter tracks outstanding operations and
  `s_waitcnt_g` / `s_waitcnt_l` are the only things that make a load's result
  visible.  This is
  what lets a wave issue a whole tile of global loads before touching any of
  them.

Branches cost a fixed 3-cycle bubble (the analogue of cpu16's `stall`).

---

## 2. Register file

| File | Count | Width | Per wave | Scope | Notes |
|------|-------|-------|----------|-------|-------|
| `s0`-`s15`  | 16 | 32 bit | 64 B | one copy per wave | addresses, strides, loop counters, lane masks |
| `v0`-`v15`  | 16 | 32 bit per lane | 1 KiB | one copy per lane | data, per-lane addresses, packed `int8x4` |
| `a0`-`a31`  | 32 | 32 bit per lane | 2 KiB | one copy per lane | matrix accumulators only |
| `exec`      | 1  | 16 bit | 2 B | one copy per wave | lane enable |
| `PC`        | 1  | 16 bit | 2 B | one copy per wave | program memory is word addressed |

Total architectural state per wave: **3138 B**, of which 2 KiB is the
accumulator file.  Four resident waves therefore need ~12.3 KiB of register
storage.  That number is the single biggest area risk in section 7.5.

### 2.1 Scalar registers

32 bits, because they hold global addresses and this machine is meant to index
more than cpu16's 256-byte data memory.  A lane mask occupies bits `[15:0]`;
mask-producing instructions write zero to bits `[31:16]`.

Sixteen of them is not generous.  Section 5.2 shows the GEMM kernel using all
16 with nothing spare, which is the intended calibration: fewer would force
spills in the hot loop, more would be dead weight.

### 2.2 Vector registers

32 bits per lane, deliberately *not* 8 bits like cpu16's data path.  A VGPR
has to be able to hold, interchangeably:

* four packed `int8` values - this is the `mma` operand format,
* one `int32` value - this is the accumulator read-back and the `C` element,
* one global byte address.

Sixteen VGPRs x 16 lanes x 4 B = 1 KiB per wave.  Section 5.3 accounts for
every one of the 16 in the GEMM inner loop.

### 2.3 Accumulator registers

32 `int32` registers per lane, organised as **two blocks of 16** (`A0` =
`a0`-`a15`, `A1` = `a16`-`a31`).  One block holds a 16 x 16 `int32` tile of
`C`: accumulator `a[m]` in lane `n` is `C[m][n]` of the tile.

Accumulators are a separate file rather than an alias of the VGPRs for two
reasons, one architectural and one physical:

* architecturally, the matrix unit needs read-modify-write access to a whole
  16-entry column every 16 cycles while the VGPRs are simultaneously feeding
  it operands; sharing one file would need far more ports;
* physically, the accumulator file only ever needs one read and one write port
  at one row per cycle, which is a much cheaper structure than the 2R1W VGPR
  file.

**Architectural requirement A1 (decided, not assumed).**  The accumulator file
**shall** sustain one **16-lane x 32-bit read-modify-write per cycle**: 64 B
read and 64 B written every cycle, for one accumulator row across all 16
lanes, concurrently with the VGPR file supplying the A and B fragments.  This
is what makes `mma_i8` a 16-cycle instruction rather than a 32-cycle one, and
every throughput number in section 7 rests on it.  It is stated here as a
requirement the implementation must meet, not as a hope: an accumulator file
that cannot do this is a failed implementation of this ISA, not a slower one.
The practical consequence is that the accumulator file is **flip-flops or a
true 1R1W macro** - a single-ported SRAM will not do - and that the write-back
must be pipelined behind the multiply.  Section 7.5 prices this at 0.95 mm^2
on sky130, the single largest area item in the design, and that is the price
of the requirement.

Access is only through:

* `mma_i8` / `mma_i8_z` - the matrix multiply-accumulate,
* `acc_zero blk` - zero a whole block,
* `acc_rd vdst, idx` - move one accumulator to a VGPR (for writing `C` out),
* `acc_wr idx, vsrc` - move a VGPR into one accumulator (for `C += ` starts).

Two blocks, not one and not four.  Section 5.4 works this out: two blocks give
a 32 x 16 output tile per wave, which is the point where the number of VGPRs
needed to feed the matrix unit (3 operands, double-buffered, = 6) plus
addresses and staging exactly fills the 16-entry VGPR file.  Four blocks would
need 5 operand registers and 10 with double buffering, leaving too few for
addressing; one block halves the reuse of the `B` fragment.

---

## 3. Memory model

Three address spaces, all byte addressed, all with 8-bit elements at the
bottom - which keeps `memory.v`'s 8-bit data word as the underlying unit.

| Space | Size | Address | Accessed by | Coherent |
|-------|------|---------|-------------|----------|
| program | 64 Ki instructions | 16 bit word address (`PC`) | fetch only | n/a |
| global  | 16 MiB | 24 bit byte address in a 32-bit register | `v_ld*_g`, `v_st*_g`, `s_ld_g` | between workgroups only at kernel boundaries |
| LDS (scratchpad) | 8 KiB | 13 bit byte address | `v_ld*_l`, `v_st*_l` | within a workgroup, after `s_barrier` |

Program memory stays separate and read-only, as in cpu8/cpu16.  cpu16's
`ld_p`/`st_p` have no gpu16 equivalent - self-modifying code on a machine
with four resident waves is not worth the second program-memory port.

### 3.1 Global memory and coalescing

The global port moves **64 B per cycle**, aligned.  A wave-wide access
produces up to 16 lane addresses; the hardware sorts them into distinct
aligned 64-byte blocks and issues **one transaction per distinct block**.

* 16 lanes each reading 4 consecutive bytes starting at a 64-byte aligned
  address: **1 transaction**, full rate.
* 16 lanes reading 4 bytes each at stride `lda` (a matrix column walk):
  **16 transactions**, 1/16 rate.

This single rule is what forces the GEMM kernel's global-to-LDS staging to map
*whole panel rows* onto each wave access rather than one matrix column per
lane (section 5.3).  It is the ISA's only concession to the memory system, and
it is a rule the programmer can reason about with a ruler.

**An honest consequence, stated here because it is easy to get wrong.**  A
`KT = 32` panel row is 32 bytes, i.e. *half* a transaction, and consecutive
panel rows are `K` bytes apart in memory, not adjacent.  So every access in
the GEMM fill touches one 64-byte block per panel row and uses only 32 bytes
of it: the fill runs at **50% transaction efficiency**, independent of the
access width.  This costs nothing at tier 1 or 2 (section 5.5 shows the fill
needs 7.3 B/cycle of transaction bandwidth out of 64) and it is not an
off-chip effect - a narrow external memory has fine granularity and moves only
the bytes asked for (section 7.5).  `KT = 64` would make a panel row exactly
one transaction and take the fill to 100%, but needs 13 KiB of LDS
(section 5.4).  The efficiency is a property of `KT`, not of the ISA.

Access widths:

* `v_ld_g` / `v_ld_gs` / `v_st_g` - one byte per lane (zero / sign extended).
* `v_ld4_g` / `v_st4_g` - four bytes per lane, address truncated to a multiple
  of 4.  16 lanes x 4 B = 64 B per access, exactly one transaction when
  contiguous.
* `v_ld16_g` / `v_st16_g` - **sixteen** bytes per lane into or out of a
  4-aligned VGPR quad, address truncated to a multiple of 16.  16 lanes x
  16 B = **256 B per access**, four transactions when contiguous.  This is the
  workhorse for any kernel that is not feeding the matrix unit, and for the
  GEMM fill; see section 4.8 for why it needs no extra register-file port.
* `s_ld_g` - one 32-bit scalar word, for kernel arguments.

There are deliberately **no** 16-byte LDS accesses.  256 bytes out of a 16-way
banked LDS takes four bank cycles however it is issued, so a `v_ld16_l` would
save issue slots but buy no bandwidth, and it would collide with the
conflict-free 36-byte-stride addressing that section 3.2 depends on.

There is no cache.  Reuse is the scratchpad's job, explicitly, in software.

### 3.2 LDS

8 KiB, shared by the 4 waves of a workgroup, organised as **16 banks of 4
bytes**; bank = `(address >> 2) & 15`.  One wave-wide 4-byte access completes
in one cycle if the 16 lane addresses hit 16 distinct banks, otherwise it
takes one cycle per conflicting way.

The banking rule has a direct consequence for tile layout that the GEMM kernel
has to respect.  A tile stored with row stride `S` bytes and read as "lane *m*
reads row *m*" hits bank `(m * S/4 + c) & 15`, which is a bijection over
*m* = 0..15 **iff `S/4` is odd**.  A natural stride of 32 bytes (`S/4 = 8`)
gives a 4-way conflict and a 4x slowdown on the hottest access in the kernel.
Padding the stride to **36 bytes** (`S/4 = 9`, coprime with 16) makes it
conflict-free.  Section 5.3 pays 2304 B instead of 2048 B of LDS for the `A`
tile to get this.

### 3.3 Synchronisation

* `s_barrier` - all waves of the workgroup wait until all have arrived.  It
  does *not* imply a memory wait; pair it with `s_waitcnt_l`.
* `s_waitcnt_g imm8` / `s_waitcnt_l imm8` - stall until at most `imm8`
  global, respectively LDS, operations are outstanding for this wave.  A
  count of 0 waits for
  everything.
* LDS writes by a wave are visible to that wave after `s_waitcnt_l`, and to
  other waves of the workgroup after `s_waitcnt_l` followed by `s_barrier`.
* Global writes are visible to other workgroups only after the kernel ends.
  There are no atomics (section 6).

---

## 4. Instruction set and encoding

### 4.1 Instruction format

Every instruction is **32 bits** and has the same shape, the way every cpu16
instruction has the same shape.  cpu16's 16-bit word cannot carry this ISA -
naming a vector destination, two vector sources, a scalar operand and a
modifier needs more than 9 bits of operand field - so the word doubles and
the field layout is regularised around a hex-digit boundary so the assembled
`.list` files stay readable.

```
|1f 1e 1d 1c 1b 1a 19 18|17 16 15 14|13 12 11 10|f e d c|b a 9 8|7 6 5 4 3 2 1 0|
|        Opcode         |    Arg0   |    Arg1   |  Arg2 |  Arg3 |      Mod      |
```

| Field | Bits | Width | Usual meaning |
|-------|------|-------|---------------|
| Opcode | `[31:24]` | 8 | 256 instructions |
| Arg0 | `[23:20]` | 4 | destination register |
| Arg1 | `[19:16]` | 4 | source 0 |
| Arg2 | `[15:12]` | 4 | source 1 |
| Arg3 | `[11:8]`  | 4 | source 2 |
| Mod  | `[7:0]`   | 8 | shift amount, byte offset, lane index, sub-opcode |

Immediate-form instructions reinterpret `{Arg2, Arg3, Mod}` as a single
signed 16-bit immediate at `[15:0]`.  This deliberately fixes the ugliest part
of cpu16, where any constant larger than 7 has to be assembled out of an
`imm` plus a chain of `imm_s`.

The assembler syntax is `op dst, src0, src1, src2` with `#` comments and
`label:` definitions; unnamed fields encode as zero.  Labels are assumed to
exist here, which is the other cpu16 gap this design does not inherit.

### 4.2 Register name encoding

The 4-bit argument fields name `s0`-`s15`, `v0`-`v15` or `a0`-`a15` depending
on the instruction, exactly as cpu16's README documents per-instruction field
meanings.  `mma_i8`'s Arg0 names an accumulator *block* (`A0` = 0, `A1` = 1);
`acc_rd` / `acc_wr` use the 8-bit Mod field to name one of 32 accumulators.

| Instructions | Arg0 | Arg1 | Arg2 | Arg3 | Mod |
|--------------|------|------|------|------|-----|
| `s_and s_or s_xor s_add s_sub s_mul s_min s_max s_shl s_shr s_sar` | s dst | s src0 | s src1 | - | - |
| `s_not s_neg s_mov` | s dst | s src0 | - | - | - |
| `s_shli s_shri s_sari` | s dst | s src0 | - | - | shift |
| `s_imm s_immh` | s dst | - | imm16 | imm16 | imm16 |
| `s_addi s_muli s_andi s_ori s_xori s_addpc` | s dst | s src0 | imm16 | imm16 | imm16 |
| `s_rd_sys` | s dst | - | - | - | sysreg |
| `s_bnz s_bz s_blz s_bgz` | - | s cond | s target | - | - |
| `s_b` | - | - | s target | - | - |
| `s_bnz_i s_bz_i` | - | s cond | imm16 | imm16 | imm16 |
| `s_b_i s_cbr_execz s_cbr_execnz` | - | - | imm16 | imm16 | imm16 |
| `s_call` | s link | - | imm16 | imm16 | imm16 |
| `s_rd_exec` | s dst | - | - | - | - |
| `s_wr_exec` | - | s src | - | - | - |
| `s_and_saveexec s_or_saveexec s_xor_saveexec` | s dst | s src | - | - | - |
| `s_exec_all` | - | - | - | - | - |
| `v_and v_or v_xor v_add v_sub v_mul v_min v_max v_shl v_shr v_sar` | v dst | v src0 | v src1 | - | - |
| `v_not v_neg v_mov` | v dst | v src0 | - | - | - |
| `v_mad v_dot4` | v dst | v src0 | v src1 | v src2 | - |
| `v_shli v_shri v_sari` | v dst | v src0 | - | - | shift |
| `v_mov_s` | v dst | s src0 | - | - | - |
| `v_add_s v_mul_s` | v dst | v src0 | s src1 | - | - |
| `v_imm v_addi` | v dst | v src0 | imm16 | imm16 | imm16 |
| `v_lane_id` | v dst | - | - | - | - |
| `v_readlane` | s dst | v src | - | - | lane |
| `v_writelane` | v dst | s src | - | - | lane |
| `v_bpermute` | v dst | v src | v index | - | - |
| `v_cmp_nz v_cmp_z v_cmp_lz v_cmp_gz` | s dst (mask) | v src | - | - | - |
| `mma_i8 mma_i8_z` | acc blk | v A frag | v B frag | - | - |
| `acc_zero` | acc blk | - | - | - | - |
| `acc_rd` | v dst | - | - | - | acc idx |
| `acc_wr` | - | v src | - | - | acc idx |
| `v_ld_g v_ld_gs v_ld4_g` | v dst | v addr | s base | - | byte offset |
| `v_st_g v_st4_g` | v src | v addr | s base | - | byte offset |
| `v_ld16_g` | v dst quad (must be 0, 4, 8 or 12) | v addr | s base | - | byte offset |
| `v_st16_g` | v src quad (must be 0, 4, 8 or 12) | v addr | s base | - | byte offset |
| `s_ld_g` | s dst | - | s base | - | byte offset |
| `v_ld_l v_ld4_l` | v dst | v addr | s base | - | byte offset |
| `v_st_l v_st4_l` | v src | v addr | s base | - | byte offset |
| `s_waitcnt_g s_waitcnt_l` | - | - | - | - | outstanding-operation count |
| `s_barrier s_endpgm s_nop` | - | - | - | - | - |

Effective address for every memory instruction is
`v[Arg1] + s[Arg2] + zext(Mod)`, and for `s_ld_g` it is `s[Arg2] + zext(Mod)`.
The three-term form is what lets the GEMM kernel keep one per-lane offset in a
VGPR, one tile base in an SGPR, and the k-step in the instruction word, so the
inner loop needs no address arithmetic at all.

### 4.3 Scalar ALU

Signed integers are 2's complement, as in cpu8/cpu16.

**The numbering is not free-form: it is cpu16's.**  Section 6.3 decision 5
settles that the scalar unit is a widened `cpu16.v`, so every operation gpu16
shares with cpu16 is given **the same opcode number cpu16 already uses**, and
cpu16's holes are left as holes rather than being compacted away.  The
decode `case` in a widened `cpu16.v` is then cpu16's own `case` with arms
added, not a renumbered one.  Section 4.13 works through what that does and
does not buy.

| Op | Opcode | binary | cpu16 | Description |
|----|--------|--------|-------|-------------|
| `s_and`  | 0x00 | 00000000 | 0 | bitwise and |
| `s_or`   | 0x01 | 00000001 | 1 | bitwise or |
| `s_not`  | 0x02 | 00000010 | 2 | bitwise not |
| `s_xor`  | 0x03 | 00000011 | 3 | bitwise xor |
| `s_add`  | 0x04 | 00000100 | 4 | addition |
| *not implemented* | 0x05 | 00000101 | 5 = `adc` | reserved for it, see below |
| `s_sub`  | 0x06 | 00000110 | 6 | subtract |
| *not implemented* | 0x07 | 00000111 | 7 = `sbb` | reserved for it, see below |
| `s_neg`  | 0x08 | 00001000 | 8 | negate |
| `s_mul`  | 0x09 | 00001001 | 9 | multiply, low 32 bits |
| *not implemented* | 0x0a | 00001010 | 10 = `div` | see below |
| `s_mov`  | 0x0b | 00001011 | 11 | move |
| `s_imm`  | 0x0c | 00001100 | 12 | `s[dst] = sext(imm16)` |
| `s_ori`  | 0x0d | 00001101 | 13 | `s[dst] = s[src0] \| sext(imm16)`; cpu16's 2-operand `or`-immediate generalised |
| `s_shli` | 0x0e | 00001110 | 14 | shift left by Mod |
| `s_shri` | 0x0f | 00001111 | 15 | logical shift right by Mod |
| *not implemented* | 0x10 | 00010000 | 16 = `rotl` | no use in the target workload |
| *not implemented* | 0x11 | 00010001 | 17 = `rotr` | as above |
| `s_sari` | 0x12 | 00010010 | 18 | arithmetic shift right by Mod |
| `s_addpc`| 0x13 | 00010011 | 19 | `s[dst] = PC_next + sext(imm16)` |
| `s_shl`  | 0x14 | 00010100 | - | shift left by `s[Arg2]` |
| `s_shr`  | 0x15 | 00010101 | - | logical shift right by `s[Arg2]` |
| `s_sar`  | 0x16 | 00010110 | - | arithmetic shift right by `s[Arg2]` |
| `s_min`  | 0x17 | 00010111 | - | signed minimum |
| `s_max`  | 0x18 | 00011000 | - | signed maximum |
| `s_immh` | 0x19 | 00011001 | - | `s[dst] = (s[dst] & 0xffff) \| (imm16 << 16)` |
| `s_addi` | 0x1a | 00011010 | - | `s[dst] = s[src0] + sext(imm16)` |
| `s_muli` | 0x1b | 00011011 | - | `s[dst] = s[src0] * sext(imm16)` |
| `s_andi` | 0x1c | 00011100 | - | `s[dst] = s[src0] & sext(imm16)` |
| `s_xori` | 0x1d | 00011101 | - | `s[dst] = s[src0] ^ sext(imm16)` |
| `s_rd_sys`| 0x1e | 00011110 | - | read system register `Mod` |

Everything with a cpu16 number in the third column has cpu16's semantics,
widened to 32 bits.  Everything without one is new, and is placed above
cpu16's highest ALU opcode so that the two ranges never interleave.

There is no `s_div`.  cpu16 has `div` at opcode 10 and it is by far the most
expensive thing in its datapath; a GEMM machine has no use for it and section
**`s_adc` and `s_sbb` (0x05, 0x07) are named but not implemented.**  These
two numbers were holes in `cpu16.v` when this document was first written and
were kept as holes for that reason; `cpu16.v` has since filled them with
add-with-carry and subtract-with-borrow beside a one-bit carry flag.  gpu16
adopts the numbers and not the instructions.  The motivation for them in
cpu16 is that an 8-bit machine cannot add two 32-bit quantities without
chaining four of them, which is a real and frequent need; gpu16's scalar
registers are already 32 bits wide and its addresses are 24, so the GEMM
kernel has no multi-word arithmetic anywhere in it.  Implementing them would
add a carry flag to the scalar unit - a piece of architectural state with its
own hazard and its own save/restore question the moment anything resembling
an interrupt appears - in exchange for nothing the target workload asks for.
Reserving the numbers costs nothing and means a later revision can add them
without disturbing anything else.

Opcode 0x0a is **reserved rather than reused**,
so that deleting `div` from a widened `cpu16.v` is deleting one `case` arm
and nothing else - and so that a future revision that wants it back does not
have to renumber.  The same applies to the two rotates.  Five wasted
encodings out of 256 is the price of the decode staying literally cpu16's.

System registers for `s_rd_sys`:

| Mod | Name | Value |
|-----|------|-------|
| 0 | `wave_id` | 0..3, this wave's index in its workgroup |
| 1 | `group_id_x` | workgroup index, N direction |
| 2 | `group_id_y` | workgroup index, M direction |
| 3 | `num_waves` | waves per workgroup (4) |
| 4 | `wave_width` | lanes per wave (16) |
| 5 | `lds_size` | bytes of LDS per workgroup (8192) |
| 8 | `perf_cycles` | free-running cycle counter |
| 9 | `perf_instrs` | instructions retired by this wave |
| 10 | `perf_mma_busy` | cycles the matrix unit has been busy |
| 11 | `perf_gmem_bytes` | global bytes moved by this workgroup |
| 12 | `perf_lds_cycles` | LDS port cycles consumed by this workgroup |

System registers 8-12 are not decoration: section 7.4 uses them to make the
benchmark self-measuring, so that tier-1 predictions can be falsified by the
RTL without a separate instrumentation harness.

### 4.4 Scalar control flow

Branch conditions compare a scalar register with zero, the same four
conditions cpu16 already defines.  Register-target forms match cpu16
exactly - **including the opcode numbers**, which needed no adjustment at
all: cpu16's branches are decimal 32-36 and gpu16's are 0x20-0x24, which are
the same five numbers.  The `_i` forms take a signed 16-bit PC-relative word
offset and exist so that programs do not have to build targets out of
shifts.

| Op | Opcode | binary | Description |
|----|--------|--------|-------------|
| `s_bnz` | 0x20 | 00100000 | branch to `s[Arg2]` if `s[Arg1] != 0` |
| `s_bz`  | 0x21 | 00100001 | branch if zero |
| `s_b`   | 0x22 | 00100010 | branch always |
| `s_blz` | 0x23 | 00100011 | branch if less than zero |
| `s_bgz` | 0x24 | 00100100 | branch if greater than zero |
| `s_bnz_i` | 0x25 | 00100101 | `PC = PC_next + imm16` if `s[Arg1] != 0` |
| `s_bz_i`  | 0x26 | 00100110 | as above, if zero |
| `s_b_i`   | 0x27 | 00100111 | unconditional relative branch |
| `s_call`  | 0x28 | 00101000 | `s[Arg0] = PC_next; PC = PC_next + imm16` |
| `s_cbr_execz`  | 0x29 | 00101001 | relative branch if `exec == 0` |
| `s_cbr_execnz` | 0x2a | 00101010 | relative branch if `exec != 0` |

Return is `s_b` through the link register.  All branches cost a 3-cycle bubble.

### 4.5 Exec mask control

| Op | Opcode | binary | Description |
|----|--------|--------|-------------|
| `s_rd_exec` | 0x30 | 00110000 | `s[dst] = exec` |
| `s_wr_exec` | 0x31 | 00110001 | `exec = s[Arg1][15:0]` |
| `s_and_saveexec` | 0x32 | 00110010 | `s[dst] = exec; exec &= s[Arg1]` |
| `s_or_saveexec`  | 0x33 | 00110011 | `s[dst] = exec; exec \|= s[Arg1]` |
| `s_xor_saveexec` | 0x34 | 00110100 | `s[dst] = exec; exec ^= s[Arg1]` |
| `s_exec_all` | 0x35 | 00110101 | `exec = 0xffff` |

### 4.6 Vector ALU

All are lane-wise and masked by `exec`.

| Op | Opcode | binary | Description |
|----|--------|--------|-------------|
| `v_and` | 0x40 | 01000000 | bitwise and |
| `v_or`  | 0x41 | 01000001 | bitwise or |
| `v_not` | 0x42 | 01000010 | bitwise not |
| `v_xor` | 0x43 | 01000011 | bitwise xor |
| `v_add` | 0x44 | 01000100 | addition |
| `v_sub` | 0x45 | 01000101 | subtract |
| `v_neg` | 0x46 | 01000110 | negate |
| `v_mul` | 0x47 | 01000111 | multiply, low 32 bits |
| `v_mad` | 0x48 | 01001000 | `v[dst] = v[src0] * v[src1] + v[src2]` |
| `v_shl` | 0x49 | 01001001 | shift left by `v[src1]` |
| `v_shr` | 0x4a | 01001010 | logical shift right |
| `v_sar` | 0x4b | 01001011 | arithmetic shift right |
| `v_mov` | 0x4c | 01001100 | move |
| `v_mov_s` | 0x4d | 01001101 | broadcast `s[src0]` to all enabled lanes |
| `v_imm` | 0x4e | 01001110 | `v[dst] = sext(imm16)` |
| `v_add_s` | 0x4f | 01001111 | `v[dst] = v[src0] + s[src1]` |
| `v_mul_s` | 0x50 | 01010000 | `v[dst] = v[src0] * s[src1]` |
| `v_shli` | 0x51 | 01010001 | shift left by Mod |
| `v_shri` | 0x52 | 01010010 | logical shift right by Mod |
| `v_sari` | 0x53 | 01010011 | arithmetic shift right by Mod |
| `v_min` | 0x54 | 01010100 | signed minimum |
| `v_max` | 0x55 | 01010101 | signed maximum |
| `v_dot4` | 0x56 | 01010110 | `v[dst] = v[src2] + sum_k sext8(v[src0].b[k]) * sext8(v[src1].b[k])` |
| `v_lane_id` | 0x57 | 01010111 | `v[dst] = lane index` |
| `v_addi` | 0x58 | 01011000 | `v[dst] = v[src0] + sext(imm16)` |
| `v_readlane` | 0x59 | 01011001 | `s[dst] = v[src] at lane Mod[3:0]` |
| `v_writelane`| 0x5a | 01011010 | `v[dst] at lane Mod[3:0] = s[src]` |
| `v_bpermute` | 0x5b | 01011011 | `v[dst] = v[src0] from lane (v[src1] & 15)` |
| `v_cmp_nz` | 0x5c | 01011100 | `s[dst] = exec & lanes(v[src] != 0)` |
| `v_cmp_z`  | 0x5d | 01011101 | `s[dst] = exec & lanes(v[src] == 0)` |
| `v_cmp_lz` | 0x5e | 01011110 | `s[dst] = exec & lanes(v[src] < 0)` |
| `v_cmp_gz` | 0x5f | 01011111 | `s[dst] = exec & lanes(v[src] > 0)` |

`v_dot4` is the scalar-per-lane sibling of `mma_i8` - four `int8` MACs in one
lane - and exists for edge tiles and for any kernel that wants dot products
without paying for the accumulator file.  It reuses one lane's slice of the
matrix unit's datapath.

### 4.7 Matrix and accumulator instructions

This is the instruction the whole design exists for.

| Op | Opcode | binary | Description |
|----|--------|--------|-------------|
| `mma_i8`   | 0x70 | 01110000 | `D += A * B`, 16x16x4 `int8` -> `int32` |
| `acc_zero` | 0x71 | 01110001 | zero accumulator block `Arg0` |
| `acc_rd`   | 0x72 | 01110010 | `v[Arg0] = a[Mod]` |
| `acc_wr`   | 0x73 | 01110011 | `a[Mod] = v[Arg1]` |
| `mma_i8_z` | 0x74 | 01110100 | `D = A * B`, same shapes, overwrite |

**`mma_i8 blk, vA, vB`** computes, for the 16 accumulators of block `blk`:

```
for m in 0..15:                      # accumulator index within the block
  for n in 0..15:                    # lane
    for k in 0..3:                   # the K step carried by one instruction
      a[16*blk + m] (lane n) += sext8(vA.byte[k] read from lane m)
                              * sext8(vB.byte[k] read from lane n)
```

So:

* `vB` is read **per lane**: lane *n* supplies the `B` fragment column *n*,
  four `int8` values for `k = k0..k0+3`.
* `vA` is read **across lanes**: lane *m* supplies the `A` fragment row *m*.
  Because the unit walks one *m* per cycle, this is a 16:1 multiplexer on a
  32-bit value, not a crossbar - an important and cheap property.
* the accumulator stays in lane *n*.

One instruction is **1024 MACs** (16 x 16 x 4).  The hardware is **64 int8
MACs wide** (16 lanes x 4 k) and the instruction occupies the matrix unit for
**16 cycles**, one accumulator row per cycle.  Back-to-back `mma` to different
blocks are allowed and pipeline cleanly; the accumulator file is interlocked
so `acc_rd` needs no manual wait.

`exec` semantics: `vA` is read from all 16 lanes regardless of `exec`, but
accumulators are updated only in lanes where `exec[n] = 1`.  Running `mma_i8`
with `exec != 0xFFFF` is legal but the A-fragment rows of disabled lanes still
participate, which is a sharp edge (section 6).

Data type is `int8 x int8 -> int32` only.  `int8` is what the underlying
8-bit memory word gives for free, and `int32` is wide enough that a `K` of
65536 cannot overflow for full-range `int8` inputs.

### 4.8 Global memory

| Op | Opcode | binary | Description |
|----|--------|--------|-------------|
| `v_ld_g`  | 0x80 | 10000000 | load 1 byte per lane, zero extend |
| `v_ld_gs` | 0x81 | 10000001 | load 1 byte per lane, sign extend |
| `v_ld4_g` | 0x82 | 10000010 | load 4 bytes per lane |
| `v_st_g`  | 0x83 | 10000011 | store low byte of `v[Arg0]` |
| `v_st4_g` | 0x84 | 10000100 | store 4 bytes per lane |
| `s_ld_g`  | 0x85 | 10000101 | load one 32-bit scalar word |
| `v_ld16_g`| 0x86 | 10000110 | load 16 bytes per lane into a VGPR quad |
| `v_st16_g`| 0x87 | 10000111 | store 16 bytes per lane from a VGPR quad |

**`v_ld16_g vdst, vaddr, sbase, mod`** loads 16 bytes per lane, little-endian,
into the four consecutive VGPRs `v[Arg0 + j]`, `j = 0..3`, where `v[Arg0+j]`
receives the bytes at lane-address `+4j`.  `Arg0` **must be a multiple of 4**;
any other value is an encoding error the assembler rejects, in the same spirit
as `asm16.cpp` hard-erroring on an oversized argument.  The effective address
is the usual `v[Arg1] + s[Arg2] + zext(Mod)`, truncated down to a multiple of
16.  `v_st16_g` is the mirror image and writes only from enabled lanes.
Disabled lanes neither read nor write, and their destination quad is left
unmodified.

**Why this costs no new register-file port.**  256 bytes at the 64 B/cycle
global port take four cycles to arrive whatever instruction asked for them, so
the return path writes one VGPR per cycle into the existing single write port
over four consecutive cycles.  A wide access is therefore a *scheduling* win -
one issue slot instead of four - not a bandwidth win.  That is exactly the
problem it was added to solve: section 7.3's memory-bound kernel was issue-
bound, not port-bound.

**The quad rule has a real cost, worth knowing before writing kernels.**  With
16 VGPRs there are exactly four aligned quads.  A kernel that keeps one live
VGPR for a per-lane address (almost all of them do) has only **three** quads
left, which is enough to hold one 64-element chunk of two operands but not
enough to double-buffer two chunks.  This is the binding constraint on the
`axpy` kernel in section 7.3.  Revision 1 called this "the strongest argument
in the document for a 32-entry VGPR file"; **section 8 checks that claim
against the numbers and withdraws it.**  The kernel it binds is already at
94.5% of the global port, so the whole prize is 5.5% on one benchmark, and
section 8.4 shows the same 5.5% is available for one dead bit of this
instruction's own `Mod` field.

### 4.9 LDS

| Op | Opcode | binary | Description |
|----|--------|--------|-------------|
| `v_ld_l`  | 0xa0 | 10100000 | load 1 byte per lane, zero extend |
| `v_ld4_l` | 0xa1 | 10100001 | load 4 bytes per lane |
| `v_st_l`  | 0xa2 | 10100010 | store low byte |
| `v_st4_l` | 0xa3 | 10100011 | store 4 bytes per lane |

### 4.10 Synchronisation and wave control

| Op | Opcode | binary | Description |
|----|--------|--------|-------------|
| `s_barrier`    | 0xb0 | 10110000 | workgroup barrier |
| `s_waitcnt_g`  | 0xb1 | 10110001 | wait until at most `Mod` **global** operations are outstanding |
| `s_waitcnt_l`  | 0xb2 | 10110010 | wait until at most `Mod` **LDS** operations are outstanding |
| `s_endpgm`     | 0xb3 | 10110011 | terminate the wave |
| `s_nop`        | 0xbf | 10111111 | no operation |

**Two counters, two instructions** (section 6.3, decision 6).  The first draft
packed both into one `Mod`, four bits each.  That is wrong for three reasons,
in increasing order of seriousness:

* it puts sub-field unpacking into the decoder, and decision 5 makes the
  decoder cpu16's, which uses its immediates whole and never unpacks nibbles -
  the two decisions push the same way;
* it caps each counter at 15, so the encoding silently couples the maximum
  depth of two unrelated queues;
* worst, with a 4-bit field "I do not care about the global counter" and "wait
  until at most 15 global operations are outstanding" are **the same
  encoding**.  That is safe only while no queue can exceed 15 entries, and
  nothing in the ISA says one cannot.

Split, each counter gets the full 8-bit `Mod` and means exactly one thing.
The cost is that a site needing both counters drained spends two instructions
instead of one.  **The GEMM kernel in section 5.3 has no such site**: every
one of its fourteen waits is unambiguously global (staging loads) or
unambiguously LDS (fragment reads, and the pre-barrier drain), so the split
changes the kernel's instruction count by zero.  That is also the evidence
that the two counters were always doing independent jobs.

### 4.11 Worked encodings

| Assembly | Opcode | Arg0 | Arg1 | Arg2 | Arg3 | Mod | Hex |
|----------|--------|------|------|------|------|-----|-----|
| `mma_i8 A1, v1, v3` | 0x70 | 1 | 1 | 3 | 0 | 0x00 | `70113000` |
| `mma_i8 A0, v1, v3` | 0x70 | 0 | 1 | 3 | 0 | 0x00 | `70013000` |
| `s_imm s9, 32` | 0x0c | 9 | 0 | imm16 = 0x0020 | | | `0c900020` |
| `v_ld4_l v1, v7, s9, 12` | 0xa1 | 1 | 7 | 9 | 0 | 0x0c | `a117900c` |
| `v_ld16_g v12, v9, s1, 0` | 0x86 | 12 | 9 | 1 | 0 | 0x00 | `86c91000` |
| `v_st16_g v4, v8, s2, 0` | 0x87 | 4 | 8 | 2 | 0 | 0x00 | `87482000` |
| `v_add_s v13, v13, s6` | 0x4f | 13 | 13 | 6 | 0 | 0x00 | `4fdd6000` |
| `acc_rd v15, 17` | 0x72 | 15 | 0 | 0 | 0 | 0x11 | `72f00011` |
| `s_cbr_execz +6` | 0x29 | 0 | 0 | imm16 = 0x0006 | | | `29000006` |
| `v_cmp_gz s4, v6` | 0x5f | 4 | 6 | 0 | 0 | 0x00 | `5f460000` |
| `s_waitcnt_g 0` | 0xb1 | 0 | 0 | 0 | 0 | 0x00 | `b1000000` |
| `s_waitcnt_l 3` | 0xb2 | 0 | 0 | 0 | 0 | 0x03 | `b2000003` |

### 4.12 Kernel launch state

At wave launch:

* `s0` = pointer to the kernel argument block in global memory,
* `s1` = `group_id_x`, `s2` = `group_id_y`,
* `exec` = `0xFFFF`, `PC` = 0,
* every other register is undefined,
* LDS contents are undefined.

The argument block layout is a kernel convention, not an ISA rule.  The GEMM
kernel uses `+0 &A`, `+4 &Bt`, `+8 &C`, `+12 M`, `+16 N`, `+20 K`.

### 4.13 Relationship to `cpu16.v`

Section 6.3 decision 5 settles that gpu16's scalar unit is **a widened
`cpu16.v`**, not a new core.  "Widened" hides six separate changes, so they
are written out here rather than left to the imagination:

| | `cpu16.v` today | gpu16 scalar unit |
|---|---|---|
| registers | 8 x 8-bit (`reg [7:0] registers[7:0]`) | 16 x 32-bit |
| register select fields | 3 bits | 4 bits |
| PC | 8-bit, 256 instructions | 16-bit, 64 Ki instructions |
| data address | 8-bit, 256 bytes | 24-bit |
| immediate | 8-bit | 16-bit |
| instruction word | 16-bit, 7-bit opcode | 32-bit, 8-bit opcode |

**What is genuinely inherited.**  Not the widths - those all change - but:

* the **control skeleton**: `IP` increment gated on `stall`, the single flat
  `case (opcode)` decode, register writeback, and the load-result-visible-one-
  cycle-later discipline that the cpu16 tests already pin down;
* the **ALU semantics**: two's complement, the same operations with the same
  meanings, and now the same opcode numbers (section 4.3);
* the **branch block verbatim**.  cpu16's branches are opcodes 32-36 and
  gpu16's are 0x20-0x24.  Those are the same five numbers, in the same order,
  with the same four compare-with-zero conditions.  This block needed no
  adjustment to align, which is the strongest single piece of evidence that
  the two ISAs really are siblings rather than a resemblance asserted in
  prose.

This is also how the two ISAs are expected to drift.  `cpu16.v` filled its
opcode holes 5 and 7 with `adc`/`sbb` after this document's first draft;
gpu16 reserves those numbers for the same two instructions and implements
neither, because a 32-bit scalar unit running GEMM has no multi-word
arithmetic (section 4.3).  Alignment means the numbers never disagree, not
that both machines implement the same set.

**What cannot align, and why.**  cpu16's memory operations are opcodes 64-69
(`ld`, `st`, `st` zero, read-modify-write, and now `ld_p`/`st_p`),
which in gpu16 is the middle of the vector ALU block.  There is no way to
reconcile this and no reason to try: gpu16 has to distinguish scalar from
vector and global from LDS, and cpu16 has no concept of either distinction.
The memory block is gpu16's own (sections 4.8, 4.9), and a widened `cpu16.v`
contributes nothing to it.

**What decision 5 turns from a nice-to-have into a prerequisite.**  Section
7.5 lists three things in `cpu16.v` that no synthesis tool will accept: `#1`
delays inside `always @(posedge clk)`, blocking assignments to sequential
state, and `initial` blocks zeroing the register file in place of a reset.  As
long as the GPU was a separate core those were a tapeout-tier concern to be
dealt with eventually.  If the GPU's scalar unit *is* this module, they become
**blocking work that comes first**, before any GPU RTL is written.  That is a
real cost of the decision and it should be counted as one.

It is also the decision's quiet benefit: that clean-up is exactly the kind of
refactor that is dangerous without tests, and the repo already has three
passing cpu16 CTests to hold it in place.  Fixing `cpu16.v` is derisked work
that improves the existing machine whether or not the GPU is ever built.

**Done.**  All three defects are gone from `cpu8.v`, `cpu16.v`, `memory.v` and
`digital_tube.v`, and `gpu16_scalar` in `gpu16.v` is written in the same
style.  The clean-up needed two things written down that statement order used
to imply: a forwarding mux, so the instruction after a load still sees the
loaded value on the edge the load writes it, and `stall_active`, which is
`stall` after the clear that used to happen part way through a cycle with a
blocking assignment.  Neither is new behaviour; the whole test suite passed
with every `.expect` file untouched, which is the derisking the paragraph
above was counting on.

**An honest measure of the saving.**  What is being reused is on the order of
forty lines of control logic and a decode table, against a GPU whose novel
content is the matrix unit, the exec mask, the scratchpad and four-wave
issue - none of which cpu16 has anything to say about.  The implementation
saving is real but modest.  The larger return is that one person's mental
model, one assembler's structure and one set of debugging habits cover both
machines, and that the README can present gpu16 as the next member of a
family rather than as an unrelated second project.

---

## 5. A worked tiled GEMM kernel

### 5.1 The problem and the tiling

```
C[M][N] (int32) += A[M][K] (int8) * Bt[N][K] (int8)
```

`B` is **pre-transposed** into `Bt[N][K]`.  This is a deliberate precondition,
not an oversight; section 5.6 measures what it would cost to drop it.

Tiling, chosen in section 5.4 and fixed here:

| Level | M extent | N extent | K extent | Holds |
|-------|----------|----------|----------|-------|
| `mma_i8` instruction | 16 | 16 | 4 | 1024 MACs, 16 matrix-unit cycles |
| wave (2 acc blocks) | 32 | 16 | 4 per step | 32 accumulators = 2 KiB |
| workgroup (4 waves, 2x2) | 64 | 32 | 32 (`KT`) | 3456 B of LDS per buffer |
| grid | `M/64` x `N/32` workgroups | | | |

LDS map, two buffers of 4096 B at offsets 0 and 4096 (a power-of-two stride so
that double buffering is one `s_xori`):

| Offset in buffer | Object | Shape | Row stride |
|------------------|--------|-------|------------|
| 0 | `As` | 64 rows (M) x 32 bytes (K) | **36 B** (padded) |
| 2304 | `Bs` | 32 rows (N) x 32 bytes (K) | **36 B** (padded) |
| 3456 | unused padding to 4096 | | |

The 36-byte stride is the bank-conflict fix from section 3.2: `36/4 = 9` is
coprime with 16, so the hot access - lane *m* reading row *m* - is
conflict-free.

Wave *w* of a workgroup owns output rows `32*(w>>1)` and columns `16*(w&1)`
of the workgroup's 64 x 32 tile.

### 5.2 Register allocation

Scalar, after setup:

| Reg | Holds |
|-----|-------|
| `s0` | K loop counter |
| `s1` | walking A fill pointer (temp within an iteration) |
| `s2` | walking Bt fill pointer |
| `s3` | A fill base for this wave, advances by `KT` each iteration |
| `s4` | Bt fill base for this wave |
| `s5` | `&C` |
| `s6` | `K` (row stride of A and Bt, in bytes) |
| `s7` | `N` |
| `s8` | `8*K`, the 8-row group stride used by the fill |
| `s9` | `As` read base: `buffer \| m_w*36` |
| `s10` | `Bs` read base: `buffer \| 2304 + n_w*36` |
| `s11` | LDS fill base for the *other* buffer |
| `s12` | wave id |
| `s13` `s14` `s15` | temporaries |

Vector:

| Reg | Holds |
|-----|-------|
| `v0` | lane id |
| `v1` `v2` `v3` | A fragment block 0, A fragment block 1, B fragment (even k step) |
| `v4` `v5` `v6` | the same for the odd k step, so LDS latency overlaps `mma` |
| `v7` | `lane*36` - the mma read offset for rows `m_w + lane` and for `Bs` |
| `v8` | `lane*36 + 576` - the mma read offset for rows `m_w + 16 + lane` |
| `v9` | global fill lane offset, `(lane>>1)*K + (lane&1)*16` |
| `v10` | LDS fill lane offset for `As`, and the C address in the epilogue |
| `v11` | LDS fill lane offset for `Bs` |
| `v12`-`v15` | the `v_ld16_g` staging quad (4-aligned, as section 4.8 requires) |

All 16 scalar and all 16 vector registers are live in the main loop.  That is
the intended calibration of both file sizes, and the staging quad is placed at
`v12` precisely because it is the only alignment that leaves the other twelve
registers usable.

### 5.3 The kernel

```
# ------------------------------------------------------------------ gemm_i8
# C[M][N] (int32) += A[M][K] (int8) * Bt[N][K] (int8)
# Preconditions: M % 64 == 0, N % 32 == 0, K % 32 == 0, B pre-transposed,
#                A, Bt, C 4-byte aligned, 4 waves per workgroup.
# Launch: s0 = &args, s1 = group_id_x, s2 = group_id_y, exec = 0xffff.

gemm_i8:
        # ---------------- scalar setup ----------------
        s_ld_g   s3,  s0, 0            # &A
        s_ld_g   s4,  s0, 4            # &Bt
        s_ld_g   s5,  s0, 8            # &C
        s_ld_g   s7,  s0, 16           # N
        s_ld_g   s6,  s0, 20           # K
        s_rd_sys s12, 0                # wave id 0..3
        v_lane_id v0
        s_waitcnt_g 0

        s_shli   s14, s2,  6           # M0 = 64 * group_id_y
        s_shli   s15, s1,  5           # N0 = 32 * group_id_x
        s_muli   s8,  s6,  8           # s8 = 8*K, the 8-row group stride

        s_shli   s13, s12, 4           # 16 * wave_id
        s_add    s13, s14, s13         # M0 + 16w
        s_mul    s13, s13, s6
        s_add    s3,  s3,  s13         # s3 = &A[M0 + 16w][0]

        s_shli   s13, s12, 3           # 8 * wave_id
        s_add    s13, s15, s13         # N0 + 8w
        s_mul    s13, s13, s6
        s_add    s4,  s4,  s13         # s4 = &Bt[N0 + 8w][0]

        # ---------------- per-lane fill offsets ----------------
        # v_ld16_g moves 16 B per lane, so one access covers EIGHT panel rows:
        # lane l covers row (l>>1) of the group, bytes (l&1)*16 .. +15
        s_imm    s13, 1
        v_and    v10, v0,  s13         # (this v_and takes a VGPR; see note)
        v_shli   v10, v10, 4           # c = (l&1)*16
        v_shri   v9,  v0,  1           # r = l>>1
        v_mul_s  v11, v9,  s6          # r*K
        v_add    v9,  v11, v10         # v9  = r*K + c          (global)
        s_imm    s13, 36
        v_shri   v11, v0,  1
        v_mul_s  v11, v11, s13         # r*36
        v_add    v11, v11, v10         # r*36 + c
        s_muli   s14, s12, 576         # wave's As row base = 16w * 36
        v_add_s  v10, v11, s14         # v10 = r*36 + c + 576w   (LDS, As)
        s_muli   s14, s12, 288         # wave's Bs row base = 8w * 36
        s_addi   s14, s14, 2304
        v_add_s  v11, v11, s14         # v11 = r*36 + c + 2304 + 288w (LDS, Bs)

        # ---------------- per-lane mma read offsets ----------------
        s_imm    s13, 36
        v_mul_s  v7,  v0,  s13         # v7 = lane*36
        v_addi   v8,  v7,  576         # v8 = lane*36 + 576

        # ---------------- compute-side tile bases ----------------
        s_shri   s13, s12, 1
        s_shli   s13, s13, 5           # m_w = 32*(w>>1)
        s_muli   s9,  s13, 36          # s9  = m_w*36         (buffer 0)
        s_andi   s14, s12, 1
        s_shli   s14, s14, 4           # n_w = 16*(w&1)
        s_muli   s10, s14, 36
        s_addi   s10, s10, 2304        # s10 = 2304 + n_w*36  (buffer 0)
        s_imm    s11, 4096             # fill into buffer 1 while computing 0
        s_mov    s0,  s6               # k counter = K

        # ---------------- prologue: fill buffer 0 ----------------
        s_imm    s11, 0
        s_call   s15, fill_tile
        s_addi   s3,  s3,  32
        s_addi   s4,  s4,  32
        s_addi   s0,  s0,  -32
        s_imm    s11, 4096
        s_waitcnt_l 0
        s_barrier

# ================================================================= main loop
kloop:
        # stage the NEXT k panel into the other LDS buffer
        s_call   s15, fill_tile

        # ---------------- compute on the current buffer ----------------
        # 8 k steps of 4, fully unrolled; Mod carries k*4 so there is no
        # address arithmetic at all in this block.
        v_ld4_l  v1, v7, s9,  0
        v_ld4_l  v2, v8, s9,  0
        v_ld4_l  v3, v7, s10, 0
        v_ld4_l  v4, v7, s9,  4
        v_ld4_l  v5, v8, s9,  4
        v_ld4_l  v6, v7, s10, 4
        s_waitcnt_l 3                  # wait for the first triple only
        mma_i8   A0, v1, v3
        mma_i8   A1, v2, v3

        v_ld4_l  v1, v7, s9,  8
        v_ld4_l  v2, v8, s9,  8
        v_ld4_l  v3, v7, s10, 8
        s_waitcnt_l 3
        mma_i8   A0, v4, v6
        mma_i8   A1, v5, v6

        v_ld4_l  v4, v7, s9,  12
        v_ld4_l  v5, v8, s9,  12
        v_ld4_l  v6, v7, s10, 12
        s_waitcnt_l 3
        mma_i8   A0, v1, v3
        mma_i8   A1, v2, v3

        v_ld4_l  v1, v7, s9,  16
        v_ld4_l  v2, v8, s9,  16
        v_ld4_l  v3, v7, s10, 16
        s_waitcnt_l 3
        mma_i8   A0, v4, v6
        mma_i8   A1, v5, v6

        v_ld4_l  v4, v7, s9,  20
        v_ld4_l  v5, v8, s9,  20
        v_ld4_l  v6, v7, s10, 20
        s_waitcnt_l 3
        mma_i8   A0, v1, v3
        mma_i8   A1, v2, v3

        v_ld4_l  v1, v7, s9,  24
        v_ld4_l  v2, v8, s9,  24
        v_ld4_l  v3, v7, s10, 24
        s_waitcnt_l 3
        mma_i8   A0, v4, v6
        mma_i8   A1, v5, v6

        v_ld4_l  v4, v7, s9,  28
        v_ld4_l  v5, v8, s9,  28
        v_ld4_l  v6, v7, s10, 28
        s_waitcnt_l 3
        mma_i8   A0, v1, v3
        mma_i8   A1, v2, v3

        s_waitcnt_l 0
        mma_i8   A0, v4, v6
        mma_i8   A1, v5, v6

        # ---------------- swap buffers and loop ----------------
        s_addi   s3,  s3,  32          # next k panel of A
        s_addi   s4,  s4,  32          # next k panel of Bt
        s_xori   s9,  s9,  4096
        s_xori   s10, s10, 4096
        s_xori   s11, s11, 4096
        s_waitcnt_l 0
        s_barrier
        s_addi   s0,  s0,  -32
        s_bnz_i  s0, kloop

# ================================================================= epilogue
        # lane n writes C[m_w + m][n_w + n] for m = 0..31
        # byte address = &C + (M0 + m_w + m)*N*4 + (N0 + n_w + n)*4
        s_shri   s13, s12, 1
        s_shli   s13, s13, 5           # m_w
        s_shli   s14, s2,  6
        s_add    s13, s14, s13         # M0 + m_w
        s_muli   s14, s7,  4           # ldc = N*4
        s_mul    s13, s13, s14
        s_add    s5,  s5,  s13         # &C[M0+m_w][0]
        s_andi   s13, s12, 1
        s_shli   s13, s13, 4
        s_shli   s15, s1,  5
        s_add    s13, s15, s13         # N0 + n_w
        s_shli   s13, s13, 2
        s_add    s5,  s5,  s13         # &C[M0+m_w][N0+n_w]
        v_shli   v10, v0,  2           # lane*4 (v10 is free after the last fill)
        s_imm    s0,  32               # 32 accumulator rows
        s_imm    s13, 0                # acc index, incremented by the encoder
wb_loop:
        # unrolled 32 times in practice; Mod names the accumulator directly
        acc_rd   v1, 0
        v_st4_g  v1, v10, s5, 0
        s_add    s5, s5, s14
        ...                            # repeated for acc 1..31
        s_endpgm

# ================================================================= fill_tile
# Stage one 64x32 A panel and one 32x32 Bt panel into LDS buffer s11.
# Each wave moves 16 A rows and 8 Bt rows.  One v_ld16_g moves 16 lanes x 16 B
# = 256 B = EIGHT whole 32-byte panel rows, so the A panel is two accesses and
# the Bt panel is one.  Each access is 8 global transactions (one 64-byte
# block per panel row, half of it used) - see section 3.1.
fill_tile:
        s_mov    s1, s3
        v_ld16_g v12, v9, s1, 0        # A rows 0..7
        s_add    s1, s1, s8            # += 8*K
        s_waitcnt_g 0
        v_st4_l  v12, v10, s11, 0
        v_st4_l  v13, v10, s11, 4
        v_st4_l  v14, v10, s11, 8
        v_st4_l  v15, v10, s11, 12
        v_ld16_g v12, v9, s1, 0        # A rows 8..15
        s_addi   s11, s11, 288         # 8 rows * 36
        s_waitcnt_g 0
        v_st4_l  v12, v10, s11, 0
        v_st4_l  v13, v10, s11, 4
        v_st4_l  v14, v10, s11, 8
        v_st4_l  v15, v10, s11, 12
        s_addi   s11, s11, -288
        # ---- Bt: 8 rows = exactly one access ----
        v_ld16_g v12, v9, s4, 0
        s_waitcnt_g 0
        v_st4_l  v12, v11, s11, 0
        v_st4_l  v13, v11, s11, 4
        v_st4_l  v14, v11, s11, 8
        v_st4_l  v15, v11, s11, 12
        s_b      s15                   # return
```

Notes on the listing:

* `v_and v10, v0, s13` is written with a scalar operand for readability; the
  encoding is `v_and` with both sources vector, so a real assembler needs
  `v_mov_s` into a scratch VGPR first.  This costs one extra instruction in
  setup only, outside the loop, and is left visible rather than silently
  fixed because it is exactly the kind of thing the first assembler
  implementation will trip over.
* The write-back loop is written with `...` because it is 32 mechanical
  `acc_rd` / `v_st4_g` / `s_add` triples; `Mod` names the accumulator so the
  sequence has no indexing logic.
* `s_waitcnt_l 3` means "at most 3 outstanding LDS operations", i.e. wait for
  the older triple while the newer triple is still in flight.  Every one of
  the fourteen waits in this listing names exactly one counter and none needs
  both, which is the argument in section 4.10 for splitting them.
* The fill has **one** staging quad, so its three `v_ld16_g` accesses cannot
  overlap each other: each one's global latency is exposed behind only four
  store instructions.  With four resident waves this is invisible - the loop
  has 1024 matrix cycles to hide it in and issues only 324 instructions - but
  on a one-wave configuration (`gpu4-tiny`, section 7.5) it is the dominant
  stall, and a second staging quad would cost a second live VGPR quad the
  file does not have.  This is the clearest place where the 16-entry VGPR file
  is too small.
* The epilogue cannot use `v_st16_g`.  Lane *n* holds `C[m][n]`, so `C` is
  contiguous *across* lanes and not *within* a lane; a wide store wants the
  opposite layout.  The 32 `acc_rd` / `v_st4_g` pairs stand.

### 5.4 Register blocking analysis

Why 2 accumulator blocks per wave, and why 16 VGPRs.

The relevant ratio is **matrix-unit cycles per operand register loaded**.  Per
k-step of 4, with `Nb` accumulator blocks:

| Acc blocks | Wave output tile | Operand VGPRs per k step | `mma` per k step | Matrix cycles per k step | Cycles per operand load |
|-----------|------------------|--------------------------|------------------|--------------------------|--------------------------|
| 1 | 16 x 16 | 2 (1 A frag, 1 B frag) | 1 | 16 | 8.0 |
| **2** | **32 x 16** | **3 (2 A frags, 1 B frag)** | **2** | **32** | **10.7** |
| 4 | 64 x 16 | 5 (4 A frags, 1 B frag) | 4 | 64 | 12.8 |
| 8 | 128 x 16 | 9 | 8 | 128 | 14.2 |

Reuse improves with more blocks but with sharply diminishing returns, because
the `B` fragment is the only thing being amortised.  The VGPR cost, however,
is linear and it is doubled by the software pipelining that hides LDS
latency:

| Acc blocks | Operand VGPRs (double-buffered) | Addresses | Fill staging | Total | Fits in 16? |
|-----------|-------------------------------|-----------|--------------|-------|-------------|
| 1 | 4 | 5 | 4 | 13 | yes, 3 spare |
| **2** | **6** | **5** | **4** | **15 + lane id = 16** | **exactly** |
| 4 | 10 | 5 | 4 | 19 + 1 | no |

and the accumulator cost is linear too: 1 block = 1 KiB per wave, 2 = 2 KiB,
4 = 4 KiB.  At 4 resident waves, 4 blocks would mean 16 KiB of accumulator
flops, which section 7.5 shows is already beyond what the silicon target can
afford.

**2 blocks is the knee**: it captures 10.7/12.8 = 84% of the operand-reuse
benefit of the 4-block design for 60% of the accumulator area, and it makes
the VGPR file exactly full at 16.

Tile size in the K direction, `KT`:

| `KT` | LDS per buffer | Double buffered | MACs per workgroup iteration | Global B per iteration | AI (MAC/B) | Fill instructions per wave | Transaction efficiency |
|------|----------------|-----------------|------------------------------|------------------------|-----------|---------------------------|------------------------|
| 8  | 64*12 + 32*12 = 1152 | 2304 | 16384 | 768 | 21.3 | 10 | 12.5% |
| 16 | 64*20 + 32*20 = 1920 | 3840 | 32768 | 1536 | 21.3 | 10 | 25% |
| **32** | **64*36 + 32*36 = 3456** | **6912** | **65536** | **3072** | **21.3** | **15** | **50%** |
| 64 | 64*68 + 32*68 = 6528 | 13056 | 131072 | 6144 | 21.3 | 30 | 100% |

("Fill instructions" counts the `v_ld16_g` accesses and their four `v_st4_l`
stores each, not the call, return and pointer arithmetic.)

Arithmetic intensity is independent of `KT` - it is set by the M x N tile
shape, not by K.  What `KT` buys is **amortisation of the barrier and the
loop overhead** against a longer run of `mma`, and what it costs is LDS.
`KT = 32` puts 6912 B into an 8 KiB scratchpad, giving 256 matrix-unit cycles
per wave between barriers.  `KT = 64` would need 13 KiB, and the extra 5 KiB
of SRAM buys only a further halving of an overhead that is already 12%.

The last column is the one argument for `KT = 64` that is not about overhead:
a 64-byte panel row is exactly one global transaction, so the fill would stop
wasting half of every block it touches (section 3.1).  It is not taken,
because at four resident waves the fill needs 7.3 B/cycle out of 64 and the
waste is free.  It would become the right call on a machine whose global port
was narrow enough for the fill to matter - which, section 7.5 notes, is
exactly what real silicon is.

### 5.5 Arithmetic intensity and where it bottlenecks

Per workgroup iteration (64 x 32 output tile, `KT = 32`):

* MACs: `64 * 32 * 32 = 65,536`
* Global bytes in: `64*32` (A) `+ 32*32` (Bt) `= 3072 B`
* **AI = 21.33 MAC/B = 42.7 int8 ops/B**

Over a whole `M = N = K = 256` GEMM, including the one-off `C` write-back:

* MACs: `16,777,216`
* Global bytes: `786,432` (A and Bt, re-read once per workgroup row/column)
  `+ 262,144` (C) `= 1,048,576 B = 1.00 MiB`
* **AI = 16.0 MAC/B**

For comparison, a naive un-tiled GEMM loads two bytes per MAC, AI = 0.5 MAC/B.
The scratchpad tiling buys **32x**, and that is the entire justification for
LDS, `s_barrier` and the three-term addressing mode existing at all.

Where it runs out of road, in the order the limits bite:

1. **The matrix unit, by design.** At 64 MAC/cycle the 256-cube GEMM needs
   262,144 cycles of matrix time; section 7.2 predicts 288,896 total, so 91%
   of all cycles are matrix cycles.  This is the intended bottleneck.
2. **Issue bandwidth at small tiles.** One instruction per cycle across four
   waves is fine here (324 issue slots against 1024 matrix cycles per
   workgroup iteration) but it is the first thing to bite for any kernel
   without `mma`.  `v_ld16_g` exists because of this: it took section 7.3's
   memory-bound kernel from 52% to 95% of the global port without widening
   anything.
3. **Global bandwidth for `A`, if `Bt` is not pre-transposed.** With the
   transpose precondition - now a fixed requirement, section 5.6 - both fills
   are whole-panel-rows-per-access.  Without it, the `Bt` fill becomes a
   16-transaction column walk plus an in-wave transpose, roughly tripling the
   fill cost.
4. **Off-chip pin bandwidth, on real silicon.** 1 MiB of useful data in
   288,896 cycles is 3.63 B/cycle, and 7.26 B/cycle of *transaction*
   bandwidth once section 3.1's 50% panel-row efficiency is counted - both
   trivially inside the 64 B/cycle on-chip port, and both *outside* what a
   hobby tapeout's pin count can deliver.  Section 7.5 shows this, not the
   ISA, is what actually limits the silicon tier.
5. **LDS bank conflicts, if the 36-byte pad is dropped.** A natural 32-byte
   stride turns the 24 conflict-free mma operand reads per iteration into 96
   port cycles, taking LDS from 19% to 56% utilised and adding ~7% to
   runtime.

Prologue and epilogue are the reason utilisation falls off at small sizes:
the 32 `acc_rd` + `v_st4_g` pairs per wave are a fixed 384 issue slots per
workgroup regardless of `K`, which is 4% of a `K = 256` run's cycles and 14%
of a `K = 64` run's - and, per section 5.3, they are the one part of the kernel
`v_st16_g` cannot help, because the accumulator layout is transposed relative
to what a wide store wants.

### 5.6 What the transpose precondition costs

If `B` arrives row-major as `B[K][N]`, the fill has to transpose it.  The
cheapest in-ISA route is: load coalesced (lane *l* takes 4 bytes of one `B`
row, 16 lanes covering 64 contiguous bytes = 2 rows), then perform a 4x4
byte transpose within groups of 4 lanes using `v_bpermute` plus byte
shifts - about 12 extra instructions per 64 B staged.  For a 32 x 32 `B`
panel that is 16 staged accesses, so **+192 instructions per workgroup
iteration**, against 400 today: a 48% increase in issue slots, still under
the 1024 matrix cycles, so **runtime barely moves** on the 4-wave machine.

The real argument for pre-transposing is therefore not speed but simplicity
and the single-wave case.  A host-side transpose is `O(KN)` once and is
amortised over `M/64` workgroup rows.

**Decided: pre-transposed `B` is a precondition of the ISA's GEMM kernel, not
an option.**  The kernel is specified against `Bt[N][K]` and is permitted to
produce garbage if handed `B[K][N]`.  The consequences are taken deliberately:
no `v_bpermute`-based transpose path is specified, the single-wave
`gpu4-tiny` configuration in section 7.5 stays viable, and the caller owns the
one-off `O(KN)` transpose.  If a future revision wants row-major `B`, it
should add a transposing *fill* helper rather than change the kernel.

---

## 6. Deliberate omissions and low-confidence areas

### 6.1 Left out on purpose

| Omitted | Why |
|---------|-----|
| Floating point of any kind | `int8 x int8 -> int32` covers the target workload; an FP32 adder alone would roughly double the matrix unit's area (section 7.5) for a workload that does not need it. |
| `bf16`/`fp16` matrix modes | Same reason.  This is the first thing to add if the machine is ever pointed at neural network *training* rather than inference. |
| `int4` / sub-byte / structured sparsity | Real accelerators win a lot here; it is pure extra decode and mux complexity on top of a design not yet built once. |
| Hardware reconvergence stack, per-lane PC | Software-managed `exec` save/restore is strictly more general, costs a handful of scalar instructions, and costs zero area.  Section 7.1's `escape` kernel measures the price. |
| Caches, coherence, memory fences | With one compute unit and an explicit scratchpad, a cache would only hide the programmer's mistakes.  Coherence across workgroups is kernel-boundary only. |
| Atomics | No reduction kernel in the target set needs them.  They would be needed for split-K GEMM. |
| `div` on either the scalar or vector side | cpu16 has it and it is the most expensive gate in that datapath.  GEMM does not divide. |
| Dynamic / ragged tile handling (`M`, `N`, `K` not multiples of the tile) | The `exec` mask plus `v_cmp_*` can do it, but the kernel would roughly double in length.  Padding the matrices host-side is the intended answer. |
| A DMA engine for global-to-LDS staging | A real accelerator would have one and it would remove 24 of the 81 instructions in the main loop.  It is a memory-system feature, not an ISA feature, and can be added later as one instruction. |
| Instruction cache, virtual memory, exceptions, traps, multi-CU dispatch | All out of scope for a machine that is one compute unit with a 64 Ki-word program memory. |
| `ld_p` / `st_p` (cpu16 implements them, on a real second program-memory port) | The port is the cheap part; the problem is that four resident waves share one program memory, so a wave rewriting an instruction would be rewriting it underneath three others. Self-modifying code needs either a private program memory per wave or a defined flush, and neither is worth it here. This is a case where the sibling ISA gained a feature gpu16 still declines. |
| ~~Wider vector loads~~ | **No longer omitted.**  `v_ld16_g` / `v_st16_g` were added at 0x86 / 0x87 (section 4.8) after the first draft showed the memory-bound kernel was *issue*-bound rather than port-bound.  They cost one bit of opcode space and a 4-alignment rule on one register field, and they buy 1.8x on `axpy` and 19 instructions per GEMM loop iteration. |
| 16-byte **LDS** accesses (`v_ld16_l`) | 256 B out of a 16-way banked scratchpad is four bank cycles however it is issued, so this saves issue slots and buys no bandwidth, and it fights the 36-byte-stride conflict-free addressing of section 3.2. |
| A `v_ld16_g` with a non-aligned destination register | Allowing any `Arg0` would need a 4-way rotate on the VGPR write port for no benefit; the assembler rejects it instead. |
| Saturating `int32 -> int8` conversion and packed byte stores | The GEMM epilogue writes `int32` `C`.  A quantised pipeline would want `v_cvt_pk_sat`. |
| Occupancy control, `s_setprio`, wave scheduling hints | Fixed at 4 resident waves. |

### 6.2 What I am least confident about

The accumulator port structure headed this list in the first draft.  It has
since been **decided** rather than assumed - requirement A1 in section 2.3 -
so it is no longer an uncertainty but a constraint the RTL must meet.  The
residual risk is recorded at the end of this section rather than in the
ranking.

In descending order of how likely it is to be wrong:

1. **The LDS bank-conflict analysis for the fill path.** Section 3.2's rule is
   worked out for the mma read (lane *m* reads row *m*, provably
   conflict-free with a 36-byte stride).  The *fill* store now maps lane *l*
   to row `l>>1` and byte column `(l&1)*16`, so store *j* of the quad hits
   bank `((l>>1)*9 + (l&1)*4 + j) & 15`.  Over the 16 lanes that is 12
   distinct banks with four of them twice, i.e. a **2-way conflict and 2 port
   cycles** instead of 1 - the same cost as the narrow fill it replaced, from
   a different pattern.  I am fairly confident in the arithmetic and much less
   confident that a real LDS implementation will actually resolve a 2-way
   conflict in exactly 2 cycles rather than 4.
2. **Whether 4 resident waves are enough to hide global latency.**  The
   double-buffered fill issues its loads one whole `KT` panel ahead, which
   gives roughly 1024 cycles of slack against an assumed 40-cycle global
   latency.  That is generous.  But the `s_waitcnt_l 0` before the barrier
   serialises the whole workgroup on the slowest wave, and I have not modelled
   barrier skew properly - the flat 32-cycle bubble in section 7.2 is a guess.
3. **The cross-lane A-fragment read.**  I claim it is a 16:1 multiplexer
   because the unit walks one `m` per cycle.  That is true if the VGPR file
   can deliver an *arbitrary* lane's 32 bits to the shared multiplier array
   each cycle, which means the VGPR file needs a read path that is not
   lane-local.  On an FPGA this is a wide mux and fine; in a small ASIC tile
   the wiring may be the thing that sets the clock period.
4. **`exec` semantics for `mma_i8`.**  Reading `vA` from disabled lanes is
   defensible but sharp.  The alternative - forcing `exec = 0xFFFF` and making
   anything else undefined - is simpler to implement and simpler to reason
   about.  I chose the more permissive rule and I am not sure it earns its
   keep.
5. **The global memory port width.** 64 B/cycle is asserted, not derived.  The
   existing `memory.v` has an 8-bit data port.  Everything in section 7 that
   is not explicitly pin-limited assumes a memory system roughly 8x wider than
   anything in this repo today, and section 7.5 is where that assumption
   collapses.
6. **The `int32` accumulator being enough.**  `K <= 65536` for full-range
   `int8` is the bound, which is comfortable.  Low confidence only in that I
   have not checked the `C += ` path where `C` already holds a large value.
7. **The exposed global latency in `fill_tile`.**  One staging quad means the
   three fill accesses serialise (section 5.3).  I claim four waves hide it;
   at one wave they certainly do not, and I have not modelled the
   intermediate case.

**Residual risk on requirement A1.**  Deciding the accumulator port structure
does not make it free.  If the implementation cannot meet one 16-lane x 32-bit
read-modify-write per cycle, `mma_i8` becomes a 32-cycle instruction, peak
throughput halves to 32 MAC/cycle, and every cycle count and GMAC/s figure in
section 7 is **2x optimistic** - while every *instruction* count, byte count
and arithmetic intensity stays exactly right, because those are properties of
the listing.  The fallback is not a redesign: it is the same ISA at half
speed, with `s_waitcnt`-visible timing unchanged (both counters).  Tier 2 measures this
directly through `perf_mma_busy`, and it is the single most valuable number
the RTL will produce.

### 6.3 Decisions taken, and what is still open

The first draft of this document ended with six open questions.  **All six
have now been answered** and are part of the specification; they are recorded
here rather than deleted, because the reasoning matters more than the
outcome.

| # | Question | Decision | Where it lands |
|---|----------|----------|----------------|
| 1 | Pre-transposed `B`: precondition, or in-kernel transpose? | **Precondition.**  The kernel takes `Bt[N][K]` and no transposing path is specified. | 5.6 |
| 2 | Wave width 16 or 32? | **16, for the first implementation.**  32 stays on the table as a later widening, not as a competing design. | 1.1, 7.5 |
| 3 | Add a wider vector load? | **Added**, as `v_ld16_g` *and* `v_st16_g`, with a test at tier 2. | 4.8, 7.4 |
| 4 | 32 accumulators per lane, or 16? | **32.** | 2.3, 5.4 |
| 5 | Should the scalar unit be a widened `cpu16.v`? | **Yes.**  The scalar opcode map is realigned onto cpu16's numbering and cpu16's holes are kept as holes. | 4.3, 4.13 |
| 6 | Should `s_waitcnt` split into two counters? | **Yes**, into `s_waitcnt_g` (0xb1) and `s_waitcnt_l` (0xb2). | 4.10 |

Five notes on the decisions, since none of them is free:

* **Wave width 16 "firstly" is a sequencing decision, not a closed one.**  The
  ISA is written so that widening to 32 changes the `exec` mask from 16 to 32
  bits - at which point a mask no longer fits half an SGPR and section 1.2's
  "masks *are* scalar registers" property is lost.  That property is worth
  more than it looks, and a 32-lane revision should expect to pay for it.
* **`v_st16_g` was added alongside `v_ld16_g` because a load-only widening
  does not solve the problem it was added for.**  Section 7.3 works this out:
  with `v_ld16_g` alone the memory-bound kernel lands at 4,018 cycles and is
  still issue-bound; with both it lands at 3,250 and is finally limited by the
  memory port.  The store is the difference between fixing the problem and
  halving it.
* **32 accumulators per lane is confirmed at the ISA level and still cannot be
  built on the smallest silicon target.**  Section 7.5's `gpu4-tiny` shrinks
  to 8 accumulators per lane to fit a TinyTapeout die.  That is a
  configuration of this ISA, not a different ISA, and the tension is real and
  unresolved: the spec says 32 and the cheapest tapeout says 8.
* **Reusing `cpu16.v` buys less implementation effort than it looks and more
  coherence than it looks.**  Every width in that module changes (section
  4.13); what survives is the control skeleton, the ALU semantics and - with
  no adjustment needed at all - the five branch opcodes.  It also promotes
  three known non-synthesisable constructs in `cpu16.v` from "clean up before
  a tapeout" to "clean up before starting", which is the decision's real
  price.  It is paid in work the repo wanted done anyway, protected by tests
  that already exist.
* **Splitting `s_waitcnt` costs the GEMM kernel nothing and removes a latent
  correctness trap.**  All fourteen waits in section 5.3 name exactly one
  counter, so the instruction count is unchanged.  The trap was that with two
  4-bit fields, "do not care about the other counter" and "wait until at most
  15 are outstanding" were the same encoding - fine today, silently wrong the
  moment a queue exceeds 15 entries.

**No questions remain open.**  What is left is not a decision but a
measurement: section 7.4's tier 2 exists to falsify the numbers, and section
6.2 lists, in order, the seven things most likely to be wrong when it does.

A seventh question was asked after revision 3 - *should the instruction word
be enlarged so a 32-entry VGPR file fits?* - and is answered in **section 8**.
It is kept separate from the table above because it is the only question whose
answer was changed by checking the premise rather than by weighing the
options: the argument for 32 registers was worth 5.5% on one benchmark and
nothing on GEMM, which is less than it cost to ask.

| 7 | Should the instruction word grow to carry 5-bit register fields? | **No.**  Absorb the `Arg3` field instead, which only `v_mad` and `v_dot4` use, and keep 16 registers implemented. | 8.5 |

---

## 7. Benchmark and evaluation plan

The point of this section is that every number above becomes falsifiable.
It defines one set of kernels and one set of metrics, and then runs them at
three tiers of increasing reality - **analytical model now, RTL simulation
once implemented, real silicon as the end goal** - using the *same* kernels
and the *same* metrics at every tier so the numbers are directly comparable.

An FPGA appears only as an optional validation step between tiers 2 and 3.
It is not the goal.

### 7.1 The benchmark kernels

Six kernels.  Three are GEMM at different sizes, two exist specifically so
the ISA is not evaluated only on the workload it was designed for, and one is
a deliberate A/B control.

| Id | Kernel | Shape | Why it is here |
|----|--------|-------|----------------|
| `gemm64`  | `C[64][64] += A[64][64] * Bt[64][64]`, int8 -> int32 | 262,144 MACs | smallest size that fills one workgroup grid; exposes prologue/epilogue overhead |
| `gemm128` | 128-cube | 2,097,152 MACs | mid size |
| `gemm256` | 256-cube | 16,777,216 MACs | the headline number |
| `axpy16k` | `y[i] += a * x[i]`, int32, `n = 16384`, narrow `v_ld4_g` / `v_st4_g` | 16,384 MACs | **memory-bound**; AI = 0.083 MAC/B.  Tests the load/store path and issue bandwidth with the matrix unit idle.  Retained as the *control*: this is the version without wide accesses. |
| `axpy16k_w` | the same kernel using `v_ld16_g` / `v_st16_g` | 16,384 MACs | the **test of the decision in 6.3** to add wide accesses.  Identical inputs and identical expected output to `axpy16k`, so it is simultaneously a correctness test of the two new opcodes and the measurement that justifies them.  If it does not beat `axpy16k`, the opcodes should be removed. |
| `escape4k` | per-point iterate `z = z*z + c` in Q12 fixed point until `\|z\|^2 > 4` or 64 iterations; `n = 4096` points, mean trip count 24 | ~196,608 MACs | **divergence-heavy**; every lane exits at a different iteration.  Tests `exec`, `v_cmp_*`, `s_and_saveexec`, `s_cbr_execz` and measures lane efficiency. |

All six have a deterministic reference output that can be checked against a
`tests/*.expect` file, exactly as the existing cpu8/cpu16 tests do.
`axpy16k` and `axpy16k_w` share one `.expect` file, which is the point of the
pair: a wide access that computes a different answer than the narrow one is a
bug in the wide access.

Input data is generated by a fixed linear congruential sequence so that every
tier produces bit-identical results and a mismatch is a bug, not a tolerance
question.  `escape4k`'s points are chosen so the mean trip count is 24 and the
mean per-wave *maximum* trip count is 58 - the gap between those two numbers
is exactly the divergence penalty being measured.

### 7.2 The metrics and the timing model

Six metrics, reported for every kernel at every tier:

| Metric | Definition |
|--------|------------|
| **Instructions** | dynamic instruction count, summed over all waves |
| **Cycles** | total cycles to kernel completion |
| **Bytes** | global memory bytes moved, read + write |
| **AI** | MACs / bytes |
| **Matrix utilisation** | `perf_mma_busy / cycles`, i.e. fraction of cycles the matrix unit is doing work |
| **Lane efficiency** | useful lane-operations / issued lane-slots; 100% for uniform kernels, less under divergence |

**Timing model "Model-A"**, which is what tier 1 uses and what tier 2 checks:

* one instruction issued per cycle per compute unit, round-robin over ready
  waves;
* scalar and vector ALU: 1 issue cycle, result bypassed, no stall;
* `mma_i8`: 1 issue cycle, occupies the matrix unit for 16 cycles; a wave
  issuing a second `mma` stalls until the unit frees;
* LDS: 1 issue cycle + 1 port cycle per conflict way; 4-cycle latency,
  non-blocking;
* global: 64 B/cycle port, one transaction per distinct aligned 64 B block,
  40-cycle latency, non-blocking;
* branch: 3-cycle bubble;
* `s_barrier`: assumed flat 32-cycle bubble per barrier for a 4-wave group.

**Baseline machine "cpu16w"**: the cpu16 ISA and pipeline exactly as in
`cpu16.v`, but with 32-bit registers and a 24-bit data address so that it can
actually hold these problems.  This fiction is necessary and is stated
plainly: the real `cpu16.v` has 8-bit registers and a 256-byte data memory,
so it cannot run `gemm64` at all.  Tier 2 therefore also runs a genuine
`gemm8` on the unmodified `cpu16.v` to anchor the cycles-per-MAC constant
empirically.

cpu16w timing, read off `cpu16.v`: 1 instruction per cycle, +1 stall cycle per
taken branch, and a load result is only visible one cycle later so a
load-use pair needs one independent instruction or a `nop` between them.

cpu16w GEMM inner loop, 10 instructions and 11 cycles per MAC:

```
        ld   r4, rA       # a = A[i][k]
        nop               # load-use gap
        ld   r5, rB       # b = Bt[j][k]
        mul  r4, r5, r6
        add  r2, r6, r2   # acc += a*b
        add  rA, r1, rA   # A ptr += 1
        add  rB, r1, rB   # Bt ptr += 1
        sub  rk, r1, rk   # k--
        bnz  rk, rT       # + 1 stall cycle
```

A hand-blocked cpu16w version that keeps two `b` values in registers and
reuses one `a` gets to about 6 cycles per MAC; both are reported, because
quoting only the naive baseline would flatter the GPU.

### 7.3 Tier 1 - predicted numbers

These are the falsifiable claims.  Everything below is computed from Model-A
and the kernel listings, not measured.

#### GEMM, gpu16

Per wave per main-loop iteration the kernel in section 5.3 issues **81
instructions** (17 A fill, 7 Bt fill, 2 barrier/wait, 48 compute, 7 loop tail)
and **16 `mma_i8`**, i.e. 256 matrix-unit cycles.  Four waves give 324 issue
slots against 1024 matrix cycles per workgroup iteration, so the matrix unit
is the limiter and a workgroup iteration costs **1024 + 32 = 1056 cycles**.
Epilogue is 96 instructions per wave (384 per workgroup) plus a ~100-cycle
store drain; prologue is ~24 per wave.

| Kernel | Workgroups | Iterations each | Instructions | Cycles | Bytes | AI (MAC/B) | Matrix util |
|--------|-----------|-----------------|--------------|--------|-------|------------|-------------|
| `gemm64`  | 2  | 2 | **2,256**   | **5,384**   | 28,672    | 9.14 | **76.1%** |
| `gemm128` | 8  | 4 | **14,208**  | **38,432**  | 163,840   | 12.8 | **85.3%** |
| `gemm256` | 32 | 8 | **98,304**  | **288,896** | 1,048,576 | 16.0 | **90.7%** |

`gemm256` at **170.7 MACs per dynamic instruction** is the headline efficiency
claim for the ISA.

**Cycles did not change when `v_ld16_g` was added, and that is the expected
result.**  The loop is matrix-bound with a 3:1 margin, so removing 19
instructions per wave per iteration removes issue slots the machine was not
short of.  Instructions per MAC improved by 20% (142.5 to 170.7) and wall
clock by nothing.  The wide load earns its place on `axpy` and on the
single-wave silicon configuration, not here; recording that plainly is more
useful than quietly claiming a GEMM win.

#### The other two kernels, gpu16

`axpy16k` (control, narrow accesses), 4-way unrolled: 20 instructions per 64
elements (8 `v_ld4_g`, 4 `v_mad`, 4 `v_st4_g`, 1 `s_waitcnt_g`, 2 `s_add`,
1 `s_addi`, 1 `s_bnz_i`), 256 chunks over 4 waves.

`axpy16k_w` (wide accesses), 2 chunks of 64 elements per loop iteration:
10 instructions per chunk (2 `v_ld16_g`, 1 `s_waitcnt_g`, 4 `v_mad`,
1 `v_st16_g`, 2 `s_add`) plus `s_addi` and `s_bnz_i` per iteration, so 22
instructions per 128 elements, 128 iterations over 4 waves.  It uses 9 VGPRs:
`v0`-`v3` for `x`, `v4`-`v7` for `y`, `v8` for the per-lane offset `lane*16`.
Only two of the four aligned quads are in use and the third cannot be paired
with a fourth, which is why the two chunks in an iteration reuse the same
registers and serialise on `s_waitcnt_g` rather than being double-buffered -
see the quad-rule note in section 4.8.

`escape4k`: 16 instructions per wave-iteration of the escape loop plus a
3-cycle branch bubble, 256 waves, mean per-wave trip count 58.

| Kernel | Instructions | Cycles | Bytes | AI | Matrix util | Lane efficiency |
|--------|--------------|--------|-------|-----|-------------|-----------------|
| `axpy16k`   | **5,120**   | **5,940**   | 196,608 | 0.083 | **0%** | 100% |
| `axpy16k_w` | **2,816**   | **3,250**   | 196,608 | 0.083 | **0%** | 100% |
| `escape4k`  | **240,640** | **285,112** | 49,152  | 4.0   | **0%** | **41.4%** |

Three findings worth stating loudly because they are the anti-GEMM results:

* `axpy16k` is **issue-bound, not memory-bound**.  It needs 3,072 cycles of
  the 64 B/cycle port but 5,120 issue slots, so it achieves 33.1 B/cycle -
  52% of the port.  This is the observation that produced `v_ld16_g`.
* `axpy16k_w` **fixes it, and stops just short of the port.** 2,816
  instructions plus 384 cycles of branch bubble plus drain gives 3,250 cycles
  against a 3,072-cycle port minimum: **60.5 B/cycle, 94.5% of the port**, and
  a 1.83x improvement over the control.  Three separate limits - issue
  (3,250), port (3,072) and per-wave load latency (~3,200) - now land within
  6% of each other, which is what a balanced kernel looks like.  For
  completeness: adding only `v_ld16_g` and keeping narrow stores gives 3,584
  instructions and **4,018 cycles**, still issue-bound; the store is over half
  of the benefit.
* `escape4k` issues 237,568 lane-slots to do 98,304 lanes of useful work.
  **41.4% lane efficiency** is the direct, quantified price of having one PC
  per 16 lanes and no hardware reconvergence.

#### cpu16w baseline

| Kernel | Instructions | Cycles (naive, 11 c/MAC) | Cycles (blocked, 6 c/MAC) | Bytes | AI |
|--------|--------------|--------------------------|---------------------------|-------|-----|
| `gemm64`  | 2,621,440   | **2,883,584**   | 1,572,864  | 540,672    | 0.48 |
| `gemm128` | 20,971,520  | **23,068,672**  | 12,582,912 | 4,259,840  | 0.49 |
| `gemm256` | 167,772,160 | **184,549,376** | 100,663,296| 33,816,576 | 0.50 |
| `axpy16k` / `axpy16k_w` | 196,608 | **212,992** | -      | 196,608    | 0.083 |
| `escape4k`| 1,376,256   | **1,572,864**   | -          | 49,152     | 4.0  |

#### Speedup summary - the claim being made

| Kernel | cpu16w cycles | gpu16 cycles | **Speedup** | vs blocked cpu16w | Instruction ratio |
|--------|---------------|--------------|-------------|--------------------|-------------------|
| `gemm64`    | 2,883,584   | 5,384   | **535x** | 292x | 1162x |
| `gemm128`   | 23,068,672  | 38,432  | **600x** | 327x | 1476x |
| `gemm256`   | 184,549,376 | 288,896 | **639x** | 348x | 1707x |
| `axpy16k`   | 212,992     | 5,940   | **35.9x** | - | 38.4x |
| `axpy16k_w` | 212,992     | 3,250   | **65.5x** | - | 69.8x |
| `escape4k`  | 1,572,864   | 285,112 | **5.5x**  | - | 5.7x |

The spread from 639x to 5.5x is the honest summary of this ISA: it is a GEMM
machine.  On a memory-bound kernel it delivers 66x from 16 lanes plus a wide
memory port - but only once wide accesses exist; without them the same kernel
gets 36x, and the 30x difference is bought by two opcodes rather than by any
hardware.  On a divergence-heavy kernel it delivers **5.5x out of a
theoretical 16x**, i.e. 34% of its own lane parallelism, and no opcode fixes
that.

Global traffic tells the same story from the other side: `gemm256` moves
1.00 MiB where cpu16w moves 33.8 MB.  **32x less memory traffic**, entirely
attributable to LDS tiling.

### 7.4 Tier 2 - RTL simulation through the existing CTest harness

Once `gpu16.v` and the assembler exist, the same six kernels run under
`iverilog` through the machinery already in the repo, with no new framework.

What has to be added:

1. **Done.**  `asm_gpu16.cpp` sits in `CMakeLists.txt` alongside `asm` and
   `asm16` and emits the section 4.1 word format as 8 hex digits per line
   under `--hex --sep_with_line`.  It is called `asm_gpu16` and not `asm32`:
   `asm` and `asm16` are named after the width of the machine they assemble
   for, so `asm32` would read as a third CPU rather than as the tool for
   gpu16.  All 97 instructions in sections 4.3 to 4.10 assemble, not only the
   scalar ones `gpu16.v` can execute; the ones no hardware can run yet are
   held down by `gpu_encoding`, which compares the words against a checked in
   expectation and so needs no core.  Labels work as sections 4.4 and 4.3
   allow them to: a word offset from `PC_next` for the `_i` branches and
   `s_call`, a plain word address for `s_imm`, and `la` as one `s_addpc`.
2. `tests/gemm64.s`, `tests/gemm128.s`, `tests/gemm256.s`, `tests/axpy16k.s`,
   `tests/axpy16k_w.s`, `tests/escape4k.s`, plus their `.data` inputs
   generated by a small committed generator, and `tests/*.expect` holding the
   reference results with `xx` for don't-care, exactly like
   `tests/cpu16_sum.expect`.  `axpy16k.s` and `axpy16k_w.s` share
   `tests/axpy16k.expect`.
3. `testgpu.v`, modelled on `test16.v`: `$readmemh` the program and data,
   run to `s_endpgm` or `+cycles`, dump the result region and compare.
4. `tests/run_gpu_test.sh`, which assembles with `asm_gpu16` and simulates
   with `testgpu.v`, gaining the kernels above as further `add_gpu_test`
   entries.
5. `tests/gpu_wide16.s` - a **correctness** test for `v_ld16_g` / `v_st16_g`
   in isolation, separate from the `axpy` performance pair, because a wide
   access has failure modes a well-behaved kernel never reaches.  It checks,
   in one program with one `.expect` file: (a) that a `v_ld16_g` of a known
   byte pattern lands little-endian in the right four VGPRs, `v[Arg0+j]`
   holding bytes `4j..4j+3`; (b) that an address not a multiple of 16 is
   truncated down rather than faulting or rotating; (c) that all four legal
   quads (`v0`, `v4`, `v8`, `v12`) behave identically, by running the same
   load into each and comparing; (d) that under a partial `exec` mask -
   `0x00ff`, then `0xaaaa` - disabled lanes neither store through `v_st16_g`
   nor have their destination quad disturbed by `v_ld16_g`, verified by
   pre-poisoning both the quad and the destination memory; (e) that a
   `v_st16_g` followed by a `v_ld16_g` of the same address round-trips only
   after `s_waitcnt_l`, which is the one hazard the ISA does *not* interlock
   (section 1.4).  The assembler side of this is **done**: `asm_gpu16`
   rejects `v_ld16_g v5, ...`, `v_st16_g v13, ...` and every other
   non-4-aligned quad register, and `gpu_reject` is the CTest that asserts
   it, along with the rest of the rules this document states that no hardware
   enforces.
6. `tests/gpu_waitcnt.s` - a test for the split counters, which exist
   precisely because the packed form could not express "do not care".  It
   issues a long run of global loads and a long run of LDS stores
   simultaneously and checks that `s_waitcnt_g N` retires the global queue to
   `N` while leaving the LDS queue untouched, and vice versa; that a count
   larger than 15 is honoured, which the old packed encoding could not
   represent; and that `s_waitcnt_l 0` followed by `s_barrier` is what makes
   one wave's LDS writes visible to another, by having wave 0 write a pattern
   that waves 1-3 read back.
7. **A regression guard for decision 5**, which is a test of the repo rather
   than of the chip: once `cpu16.v` has been made synthesisable, the three
   existing cpu16 CTests must still pass unchanged.  They are the only thing
   standing between that refactor and a silent behaviour change, and they
   should be run before and after rather than only after.
8. `tests/cpu16_gemm8.s` - a genuine 8x8x8 GEMM on the **unmodified**
   `cpu16.v`.  `A` is 64 B, `Bt` is 64 B and an `int16` `C` is 128 B, which
   is exactly the 256 bytes of `cpu16.v`'s data memory.  512 MACs at a
   predicted 11 cycles each is **5,632 cycles plus ~40 of setup**.  This is
   the one baseline number that is measured on real existing RTL rather than
   asserted, and it calibrates the cycles-per-MAC constant that the whole
   cpu16w column depends on.

**How tier 1 gets falsified.**  The kernels read their own performance
counters (`s_rd_sys` 8-12, section 4.3) and store them to a known address, so
the `.expect` file contains not just the result matrix but the cycle count,
instruction count, matrix-busy count and byte count.  A new
`tests/*.perf.expect` carries the tier-1 prediction with a tolerance band, and
the CTest entry fails if the RTL lands outside it.  Predicted bands:

| Kernel | Predicted cycles | Pass band | Falsified if |
|--------|------------------|-----------|--------------|
| `gemm64`   | 5,384   | +/- 15% | outside 4,576 - 6,192 |
| `gemm128`  | 38,432  | +/- 12% | outside 33,820 - 43,044 |
| `gemm256`  | 288,896 | +/- 10% | outside 260,006 - 317,786 |
| `axpy16k`  | 5,940   | +/- 15% | outside 5,049 - 6,831 |
| `axpy16k_w`| 3,250   | +/- 15% | outside 2,763 - 3,738 |
| `escape4k` | 285,112 | +/- 20% | outside 228,090 - 342,134 |
| `cpu16_gemm8` (real cpu16.v) | 5,672 | +/- 5% | outside 5,388 - 5,956 |

Instruction counts are predicted with no tolerance at all - they are a
property of the listing, not the microarchitecture.  If the RTL retires a
number of instructions different from the table in 7.3, either the assembler
or the prediction is simply wrong.

The most likely way tier 1 is wrong, in order: the barrier bubble (guessed at
32 cycles), the LDS 2-way conflict resolution, and whether the matrix unit
really accepts a new `mma` every 16 cycles with no pipeline drain between
accumulator blocks - i.e. whether requirement A1 of section 2.3 was met.  If
it was not, every GEMM cycle count above should come in at roughly 2x and
every instruction count should be exactly right, which makes the two failure
modes easy to tell apart from one test run.

There is also one prediction here that is a genuine A/B experiment rather than
a model check: **`axpy16k_w` must beat `axpy16k` by 1.5x or more**.  It is
predicted at 1.83x.  If the RTL shows less than 1.5x, the wide accesses are
not paying for their decode and alignment rules and section 6.3's decision 3
should be reversed - the kernels are written so that reversing it means
deleting two opcodes and one test, and nothing else.

### 7.5 Tier 3 - real silicon

The end goal is not a waveform.  It is a packaged part running `gemm256` at a
real clock on real memory, with a wall-clock time and a throughput figure
measured with an oscilloscope or a host timer.

#### Routes a hobby project actually has

| Route | Process | User area | IO | Cost | Status |
|-------|---------|-----------|----|------|--------|
| **TinyTapeout** | SkyWater sky130 (and IHP sg13g2 rounds) | one tile = 160 x 100 um = **0.016 mm2**; multi-tile up to ~16 tiles = **0.26 mm2** | 8 in, 8 out, 8 bidir, 1 clock, 1 reset, shared with all other projects via a scan chain | roughly **$100 for 1 tile**, scaling up for multi-tile, plus ~$100 for the demo board | live, several rounds per year |
| **Efabless ChipIgnite / caravel harness** | sky130 | user project area **2.92 x 3.52 mm = 10.2 mm2**, ~38 GPIO via a management SoC | ~38 GPIO at modest speed | historically ~**$10,000** for a slot with 100 packaged parts | **uncertain** - Efabless wound down in 2025; treat this route as not currently guaranteed |
| **IHP Open Source shuttles** | IHP sg13g2, 130 nm BiCMOS, fully open PDK | varies by call, of order a few mm2 | call-dependent | free for open-source projects when a call is open | live |
| Commercial 130 nm MPW (Europractice, MOSIS) | various | a few mm2 | full custom pad ring | **EUR 5k - 20k** | always available, needs an institution |

Pricing and availability above should be re-checked before committing; they
move, and the Efabless situation in particular.

#### What the design must satisfy to be tapeout-eligible

This is a checklist against the current repo, and the current repo fails most
of it:

1. **Synthesisable RTL with no simulation-only constructs.**  *Done for the
   CPUs.*  `cpu16.v` used to use `#1` delays inside `always @(posedge clk)`
   and blocking assignments to sequential state, neither of which survives
   synthesis; it now has an asynchronous reset and writes all sequential
   state with non-blocking assignments, as do `cpu8.v`, `memory.v` and
   `gpu16.v`.  The one `$display` left in each is the `unknown opcode` arm,
   which synthesis ignores and the test harness greps for.  `gpu16.v` must be written
   with non-blocking assignments to all sequential state, no `#` delays, no
   `initial` blocks for reset state, and no `$display`.
   **Section 6.3's decision 5 escalates this from tier-3 hygiene to tier-2
   blocking work**: if the scalar unit *is* a widened `cpu16.v`, then
   `cpu16.v` has to be made synthesisable before the GPU is started, not
   before it is taped out.  Section 4.13 argues this is the cheapest moment
   to pay it, because the three existing cpu16 CTests already protect the
   refactor.
2. **A defined clock and reset strategy.**  One clock domain, one
   synchronous active-low reset that initialises `PC`, `exec`, the wave
   scoreboard and nothing else; register files and memories come up
   undefined and must be written before being read.  The `initial` loops that
   zero the register file in `cpu16.v` have to become reset logic or be
   deleted.  (`cpu8_simd.v` carried the same problem and has since been
   deleted from the repo outright, which is the cheaper fix where it applies.)
3. **Memories as macros or as flops, explicitly.**  `memory.v` infers a RAM,
   which is fine for FPGA and wrong for ASIC.  Each memory must be either an
   instantiated SRAM macro (`sky130_sram_1rw1r_32x256_8`, 1 KiB, ~0.12 mm2
   each) or an explicit flop array, chosen per memory by size.  The repo's
   Xilinx-specific `memory_ramb18e1.v` wrapper has since been deleted, which
   removes the risk of it reaching an ASIC build by accident but also removes
   the FPGA path noted below.
4. **Test data on and off chip through a very limited pin count.**  This is
   the hard constraint and it dominates tier 3 performance.
5. **No combinational loops, no latches, no multiply/divide inference that
   blows up area** - in particular cpu16's `div` must not exist (section 6.1).
6. **DFT**: at minimum the TinyTapeout scan wrapper, which is provided.

#### Host data in and results out

| Route | Mechanism | Bandwidth at 40 MHz |
|-------|-----------|---------------------|
| TinyTapeout | the 8 bidirectional pins driven as a QSPI master to an external PSRAM PMOD, or as a byte-at-a-time handshake to the host RP2040 on the demo board | QSPI x4 at 40 MHz = **~20 MB/s** |
| caravel-class | ~16 of the 38 GPIO as a 16-bit SRAM/HyperRAM interface | 16 bit x 40 MHz = **80 MB/s** |

There is no scenario in which a hobby tapeout gets a 64 B/cycle global port.
The ISA's memory model survives - it is still a byte-addressed global space
with a coalescing rule - but the *port* shrinks by a factor of 30 or more,
and that is what actually limits tier 3.

#### Area budget in sky130

Anchors: a `sky130_fd_sc_hd` NAND2 is about 3.75 um2 and a D flip-flop about
10 um2, so at a realistic 50-60% placement utilisation the usable density is
roughly **150 kGE/mm2** and **100,000 flip-flops per mm2**.  An 8x8 signed
multiplier with a 32-bit accumulate adder is about 1.1 kGE.

`gpu16-full` exactly as specified in sections 1-4:

| Block | Sizing | Area |
|-------|--------|------|
| Matrix unit, 64 int8 MACs | 64 x 1.1 kGE = 70 kGE | **0.47 mm2** |
| Accumulator file, 4 waves x 32 x 32 b x 16 lanes = 65,536 flops | + read/write muxing | **0.95 mm2** |
| VGPR file, 4 waves x 16 x 32 b x 16 lanes = 32,768 flops | + 2R1W muxing and the cross-lane read path | **0.55 mm2** |
| LDS 8 KiB | 8 x `sram_1rw1r_32x256_8` macros | **0.96 mm2** |
| SGPRs, decode, scheduler, scoreboard, barrier, address coalescer | ~45 kGE | **0.30 mm2** |
| Global port and pad logic | | **0.10 mm2** |
| **Total** | | **~3.3 mm2** |

That fits a caravel-class 10.2 mm2 user area with room to spare, and is
**13x too big for even a 16-tile TinyTapeout**.

So there are two silicon configurations, and the honest conclusion is that
**the specification as written does not fit the cheap route**:

| | `gpu16-full` | `gpu4-tiny` |
|---|---|---|
| Lanes | 16 | **4** |
| Matrix unit | 16 x 4 = 64 MAC/cycle | **4 x 2 = 8 MAC/cycle** |
| VGPRs | 16 x 32 b | **8 x 32 b** |
| Accumulators | 32 per lane (2 blocks of 16) | **8 per lane (2 blocks of 4)** |
| SGPRs | 16 x 32 b | **8 x 32 b** |
| LDS | 8 KiB SRAM macros | **256 B of flops** |
| Resident waves | 4 | **1** |
| `mma_i8` shape | 16 x 16 x 4 | **4 x 4 x 2** |
| Area (sky130) | ~3.3 mm2 | **~0.19 mm2 = 12 TT tiles** |
| Route | caravel-class MPW | **TinyTapeout** |

`gpu4-tiny` area breakdown: 8 MACs = 8.8 kGE = 0.06 mm2; accumulators
8 x 32 b x 4 lanes = 1024 flops = 0.026 mm2 with muxing; VGPRs 1024 flops =
0.026 mm2; SGPRs 256 flops = 0.007 mm2; 256 B LDS as 2048 flops = 0.04 mm2;
decode and control 0.03 mm2.

**Which ISA choices survive the area budget:**

| Choice | Survives? | Note |
|--------|-----------|------|
| 32-bit uniform instruction word, 8/4/4/4/4/8 fields | **yes** | decode is 0.5% of area at either size; the 4-bit fields simply address fewer registers |
| Software-managed `exec` reconvergence | **yes** | this is the choice that pays off most - it is literally free in area |
| `int8 x int8 -> int32` and no floating point | **yes, and is the reason anything fits** | an FP32 matrix unit would be ~4x the MAC area |
| Separate accumulator file | **yes**, but it is the biggest single item | 0.95 mm2 of 3.3 mm2 in the full config |
| No `div` | **yes** | saves ~15 kGE |
| Three-term addressing `v + s + imm8` | **yes** | one adder per lane |
| `v_ld16_g` / `v_st16_g` | **yes, and they matter more here than at tier 1** | no extra register-file port (section 4.8) and negligible decode, while the one-wave TinyTapeout configuration has no other way to hide latency: with a single wave, saving three issue slots out of four on every fill access is not a rounding error |
| Requirement A1, the 16-lane accumulator read-modify-write | **yes at 4 lanes, unproven at 16** | as flops it is just a wide enable; the risk is the write-back path timing, not the area |
| **Wave width 16** | **no on TinyTapeout** | must drop to 4; 16 lanes of datapath and register file is ~2 mm2 on its own |
| **32 accumulators per lane** | **no on TinyTapeout** | must drop to 8; this is the dominant flop cost, and it is the one place where the ISA as specified (section 6.3, decision 4) and the cheapest tapeout openly disagree |
| **8 KiB LDS** | **no on TinyTapeout** | must drop to 256 B, which forces `KT = 8` and drops AI from 21.3 to 2.67 MAC/B |
| **64 B/cycle global port** | **no anywhere** | pin-limited to 20-80 MB/s; see the wall-clock numbers below |
| **4 resident waves** | **no on TinyTapeout** | one wave, so all the latency hiding in section 5.3 stops working and the matrix unit idles during fills |

The rows that say "no anywhere" and "no on TinyTapeout" are the real finding:
**on a hobby tapeout the ISA is not the limit - pins and scratchpad are.**
Note which way the wide accesses fall.  They were added to fix a tier-1
issue-bandwidth problem, they changed no GEMM cycle count at tier 1, and they
survive to tier 3 as one of the few ISA features that gets *more* valuable as
the machine gets smaller.  That is an argument for judging an ISA feature at
the tier where the machine is cheapest, not the tier where it is fastest.

#### Predicted tier-3 numbers

Clock: sky130 through the open OpenLane flow, for a design of this shape, is
realistically **40 MHz**.  The critical path is expected to be the
cross-lane A-fragment read into the multiplier array (section 6.2 item 4).

`gpu16-full`, `gemm256`: compute needs 288,896 cycles = 7.22 ms at 40 MHz, but
the 1.00 MiB of global traffic through an 80 MB/s 16-bit port needs 13.1 ms.
**Memory-limited.**

`gpu4-tiny`, `gemm256`: with 256 B of LDS, `KT = 8` and an 8 x 4 wave tile, AI
falls to 2.67 MAC/B, so traffic is 6.55 MB.  Compute needs 2.1 M cycles =
52 ms; the 20 MB/s QSPI needs 327 ms.  **Memory-limited by 6.3x.**

| Design | Clock | `gemm256` wall clock | Throughput | Matrix util | Limit |
|--------|-------|---------------------|------------|-------------|-------|
| `cpu16w` in sky130 | 40 MHz | **4.61 s** | 3.64 MMAC/s | n/a | compute |
| `gpu4-tiny` (TinyTapeout) | 40 MHz | **330 ms** | **50.8 MMAC/s** | ~16% | QSPI pins |
| `gpu16-full` (caravel-class) | 40 MHz | **13.1 ms** | **1.28 GMAC/s** | ~50% | 16-bit port |
| `gpu16-full` if the port were not the limit | 40 MHz | 7.22 ms | 2.32 GMAC/s | 90.7% | matrix unit |

Silicon speedup of `gpu16-full` over `cpu16w` is **352x**, not the 639x of
section 7.3, because the GPU is pin-limited and the scalar CPU is not.  That
gap is the single most useful thing tier 3 will teach this project.

#### Optional intermediate: FPGA validation

The repo used to carry a `memory_ramb18e1.v` wrapper around a Xilinx block
RAM primitive, which implied a 7-series target; it has since been deleted, so
this step now starts from inferred memories rather than from existing code.
An Artix-7 board (Arty A7-100T, ~$270) remains the natural intermediate
step.
`gpu16-full` needs 64 int8 MACs (32 DSP48E1 slices packing two int8 MACs
each, of 240 available), 8 KiB of LDS as 8 BRAM18 in 16 banks, and the
register files in distributed RAM.  100 MHz is comfortable, and the board's
DDR3 delivers ~1.3 GB/s against the 363 MB/s the kernel wants at 100 MHz, so the FPGA is
**compute-bound where the silicon is not**:

`gpu16-full` on Artix-7 at 100 MHz: 288,896 cycles = **2.89 ms**,
**5.81 GMAC/s** - 4.5x *faster* than the sky130 part.

Saying that plainly: if the goal were performance, the project should stop at
the FPGA.  Tier 3 is justified by wanting real silicon, not by speed.

### 7.6 Cost, area and power - the other half of the comparison

Speed alone would let this ISA justify itself too easily.  Every design is
therefore also reported with its area, its estimated power, and what it costs
to get a working part.

Power estimates use a 130 nm, 1.8 V anchor: `alpha * C * V^2` with
`alpha = 0.1`, `C = 2 fF` per gate gives **26 nW per gate per MHz-of-clock** at
40 MHz, i.e. 26 nW/gate.  Pad power is added separately and dominates the
small designs.

| Design | Area (sky130) | Gates (approx) | Est. power | Basis |
|--------|---------------|----------------|-----------|-------|
| `cpu16` as it exists (8-bit, 256 B memories) | **0.08 mm2** | 12 kGE incl. flop memories | **~3 mW** | 0.3 mW core + ~3 mW pads |
| `cpu16w` (32-bit, external memory) | **0.05 mm2** core | 8 kGE | **~5 mW** | pad-dominated |
| `gpu4-tiny` | **0.19 mm2** | 30 kGE | **~4 mW** | 0.8 mW core + pads |
| `gpu16-full` | **3.3 mm2** | ~400 kGE + 8 KiB SRAM | **~25 mW** | 10 mW logic + 5 mW SRAM + 10 mW pads |
| `gpu16-full` on Artix-7 | n/a | n/a | **~2 W** | whole board |

Cost to a first working chip, all-in:

| Design | Route | Shuttle / board | Tools | Other | **Total** | Lead time |
|--------|-------|-----------------|-------|-------|-----------|-----------|
| `cpu16` | TinyTapeout, ~5 tiles | ~$200 | $0 (OpenLane, open PDK) | ~$100 demo board | **~$300** | 6-9 months |
| `gpu4-tiny` | TinyTapeout, 12 tiles | ~$500 | $0 | ~$100 demo board + ~$20 PSRAM PMOD | **~$620** | 6-9 months |
| `gpu16-full` | caravel-class MPW | ~$10,000 | $0 | ~$500 test rig and external RAM board | **~$10,500** | 9-12 months |
| `gpu16-full` | Artix-7 FPGA only | $270 | $0 (Vivado free edition) | - | **$270** | days |

Derived figures - this is the table that decides whether the GPU ISA earns
its extra area and money:

| Design | `gemm256` throughput | Area mm2 | **GMAC/s per mm2** | Power | **GMAC/s per W** | **pJ per MAC** | **$ to first chip** |
|--------|---------------------|----------|--------------------|-------|-------------------|----------------|---------------------|
| `cpu16w` | 0.00364 GMAC/s | 0.05 | **0.073** | 5 mW | **0.73** | **1374** | $300 |
| `gpu4-tiny` | 0.0508 GMAC/s | 0.19 | **0.267** | 4 mW | **12.7** | **79** | $620 |
| `gpu16-full` | 1.28 GMAC/s | 3.3 | **0.39** | 25 mW | **51.2** | **19.5** | $10,500 |
| `gpu16-full`, not pin-limited | 2.32 GMAC/s | 3.3 | **0.70** | 25 mW | **92.8** | **10.8** | - |
| `gpu16-full` on Artix-7 | 5.81 GMAC/s | n/a | n/a | ~2 W | **2.9** | **344** | $270 |

Read honestly, that table says:

* **Area efficiency: the GPU ISA wins by 5.3x** (0.39 vs 0.073 GMAC/s/mm2),
  or 9.6x if the off-chip port were not the limit.  Real, but far smaller
  than the 352x speedup, because the GPU spends most of its area on register
  files and scratchpad rather than on multipliers.
* **Energy efficiency: the GPU ISA wins by 70x** (51.2 vs 0.73 GMAC/s/W;
  19.5 vs 1374 pJ/MAC).  This is the strongest argument for the design, and
  it comes almost entirely from amortising one instruction fetch over 1024
  MACs instead of over one.
* **Cost: the GPU ISA loses by 35x** ($10,500 vs $300).  The dominant cost is
  the shuttle slot, which is priced by area, and area is what the design
  spends.
* **`gpu4-tiny` is the best value**: 14x the throughput of `cpu16w` for 2x the
  cost and 3.8x the area, on the same cheap shuttle.  If the point is to have
  a working GPU in silicon rather than a fast one, `gpu4-tiny` is the correct
  first tapeout and `gpu16-full` should stay on the FPGA.
* **The FPGA is 4.5x faster and 39x cheaper than the ASIC, and 18x worse per
  watt.**  Which of those three numbers matters is a decision about what the
  project is for, not a technical question.

#### Predicted cost and power numbers, stated for falsification

| Prediction | Value | Falsified if |
|-----------|-------|--------------|
| `gpu16-full` sky130 area after synthesis and place-and-route | **3.3 mm2** | outside 2.3 - 4.6 mm2 |
| `gpu4-tiny` sky130 area | **0.19 mm2** | it does not fit 16 TinyTapeout tiles (0.26 mm2) |
| `gpu16-full` achieved clock, OpenLane sky130 | **40 MHz** | below 25 MHz or above 80 MHz |
| `gpu16-full` post-layout power at 40 MHz | **25 mW** | outside 12 - 50 mW |
| `gpu16-full` `gemm256` wall clock on silicon | **13.1 ms** | outside 9 - 20 ms |
| `gpu4-tiny` `gemm256` wall clock on silicon | **330 ms** | outside 230 - 470 ms |
| `gpu16-full` on Artix-7 at 100 MHz | **2.89 ms**, 5.81 GMAC/s | outside 2.4 - 3.6 ms |
| Artix-7 resource use | 32 DSP48E1, 8 BRAM18, ~12k LUT | above 64 DSP or 32 BRAM18 |
| Total cost to `gpu4-tiny` first silicon | **~$620** | above $1,200 |
| GMAC/s/mm2 advantage over `cpu16w` | **5.3x** | below 3x or above 12x |
| GMAC/s/W advantage over `cpu16w` | **70x** | below 30x or above 150x |

Every one of these is checkable.  The area, clock and power numbers come out
of OpenLane the first time the design is hardened; the wall-clock numbers come
out of a host timer on the demo board; the tier-1 cycle counts come out of
CTest as soon as the RTL exists.

---

## 8. Revision 4: should the instruction word grow to 32 registers?

Revision 3 ended with one item for the reviewer: `v_ld16_g` needs a 4-aligned
VGPR quad, 16 VGPRs contain exactly four quads, a kernel holding a per-lane
address register keeps only three, and three is enough to hold one chunk of
two operands but not to double-buffer two.  Section 4.8 called that "the
strongest argument in the document for a 32-entry VGPR file".  The reviewer
asked the obvious follow-up: **32 registers need a 5-bit field, so should the
instruction word grow to carry one?**

This section answers that.  The short version is that the question contains a
buried assumption worth examining before any of the three options is costed.

### 8.1 First, how much is the problem actually worth?

Section 4.8's claim was written from the encoding side and never checked
against section 7.3's numbers.  Checking it changes the answer.

The kernel the quad rule binds is `axpy16k_w`, and section 7.3 already reports
it at **3,250 cycles against a 3,072-cycle global-port floor - 94.5% of the
port**.  Double-buffering cannot create bandwidth.  The most it can do is hide
the remaining latency and the branch bubbles, so:

> **The entire prize for fixing the double-buffering problem is 178 cycles,
> or 5.5%, on one of six benchmark kernels.**

And it cannot help the kernel the ISA exists for.  `gemm256` runs at
**90.7% matrix utilisation** (288,896 cycles against a 262,144-cycle matrix
floor).  The 26,752-cycle gap is 32 cycles of barrier bubble per workgroup
iteration plus the prologue and epilogue - section 5.4's accounting attributes
none of it to register pressure, because the main loop's fill is already
overlapped with `mma` by the two-phase `v1`-`v3` / `v4`-`v6` fragment split.
More registers do not shorten a barrier.  A 32-entry VGPR file changes
`gemm64`, `gemm128` and `gemm256` by **zero cycles and zero instructions**.

So the true shape of the question is: what is a 5.5% improvement on the
*least* important benchmark worth paying for?  That reframing does most of the
work below, and it is the single most useful thing this section establishes.
It should have been checked in revision 2, when `axpy16k_w`'s 94.5% figure was
first computed; writing "strongest argument for 32 registers" two sections
away from "94.5% of port" is exactly the kind of mistake a document this size
invites.

### 8.2 Option (a) - keep 32-bit instructions and 16 VGPRs

Do nothing.  Kernels live with three usable quads and no double-buffering.

| | |
|---|---|
| Section 7.3 effect | baseline: `gemm*` unchanged, `axpy16k_w` 2,816 instructions / 3,250 cycles, 94.5% of port |
| Section 7.5 area | `gpu16-full` **3.3 mm2**; `gpu4-tiny` **0.19 mm2 = 12 TinyTapeout tiles** |
| Section 7.6 cost | **$620** to a first `gpu4-tiny` chip; 0.39 GMAC/s/mm2 |
| Encoding | unchanged |
| Risk | a future kernel with more live state than `axpy` has no room at all |

The cost of option (a) is not the 5.5%.  It is that **the 5th bit is gone
forever**.  Once `v_mad`'s Arg3 and the 8-bit Mod are both spent, there is no
32-bit rearrangement that yields 5-bit register fields later without
renumbering every instruction in the ISA - the one thing section 4.13 just
spent a page arguing gpu16 should never do to its own encoding, having gone to
some trouble to align with cpu16's.

That is the genuine argument against (a), and it is an argument about
option value, not about performance.

### 8.3 Option (b) - widen the instruction word

Carry 5-bit register fields by growing the word to 40, 48 or 64 bits.

**What it does *not* cost.**  Two objections that look obvious are wrong and
should be dismissed rather than used as padding:

* *Alignment.* Program memory is word-addressed and separate (section 3), so a
  40-bit or 48-bit instruction word is entirely legal - `PC` indexes words,
  not bytes.  Harvard architecture is what makes this a non-issue, and the
  `.list` readability requirement of section 4.1 survives too: 40 bits is 10
  hex digits, 48 is 12.  This is a real freedom, not a constraint.
* *Fetch bandwidth.* One instruction per cycle per CU is 4 B/cycle at 32 bits
  and 8 B/cycle at 64.  Against a 64 B/cycle global port that is noise.

**What it does cost.**

1. **Program-memory area, paid on every instruction whether or not it uses a
   high register.**  Section 7.5's area table omits program memory entirely,
   which is an omission in this document and is corrected here.  The six
   benchmark kernels are a few hundred static instructions, so a realistic
   store is 512 instructions: **2 KiB at 32 bits, about 0.24 mm2** in
   sky130 SRAM macros at section 7.5's 0.12 mm2/KiB.  At 64 bits it is 4 KiB
   and **0.48 mm2**.

   > **Widening the word to afford 32 registers costs +0.24 mm2; simply
   > building the 32 registers costs +0.55 mm2.  The tax on the instruction
   > path is roughly half the price of the thing it is trying to buy, and it
   > is paid by every configuration, including the ones that implement 8
   > registers and can never use the field.**

2. **The scalar half of the ISA pays all of it and gets none of it.**  A
   scalar ALU instruction needs 8 bits of opcode and three 4-bit register
   fields - 20 bits.  A scalar immediate form needs 8 + 4 + 4 + 16 = 32.
   Nothing in the scalar half wants a 5-bit vector field.  In a 64-bit word,
   every `s_add` in every kernel carries 32 dead bits.
3. **It is the one change that damages the section 4.13 relationship.**  The
   scalar unit is a widened `cpu16.v`, and the family story is that the word
   doubles: 16 bits for cpu16, 32 for gpu16.  40 and 48 break the pattern
   outright.  64 preserves it arithmetically while doubling the padding in
   point 2.  This is soft, but section 4.13 is the only thing making these two
   machines a family rather than two projects, and it was committed to one
   revision ago on the reviewer's own instruction.
4. **A variable-length compromise is worse than either.**  32-bit scalar plus
   64-bit vector instructions would fix point 2, at the price of a length bit,
   a fetch path that can straddle, and the loss of "every instruction has the
   same shape" - a property section 4.1 inherits deliberately from cpu8 and
   cpu16 and the single largest reason this ISA is small enough for one person
   to implement.  Rejected.

| | 64-bit word + 32 VGPRs |
|---|---|
| Section 7.3 effect | `gemm*` **unchanged**; `axpy16k_w` 3,250 -> ~3,072 cycles, **5.5% better**, instruction counts unchanged |
| Section 7.5 area | `gpu16-full` 3.3 -> **4.09 mm2** (+0.55 registers, +0.24 program memory); `gpu4-tiny` 0.19 -> **0.27 mm2 = about 17 tiles**, before counting its wider program store |
| Section 7.6 cost | `gpu4-tiny` **falls off TinyTapeout**, whose ceiling is about 16 tiles - the $620 route is lost |
| Section 7.6 derived | `gpu16-full` area efficiency **0.39 -> 0.31 GMAC/s/mm2, a 19% regression in the headline metric** |

That last row is the verdict on option (b).  It buys 5.5% on the benchmark
that matters least and gives back **19%** of the number section 7.6 uses to
justify the entire design.  `gemm256` throughput is unchanged at 1.28 GMAC/s
because the kernel is matrix-bound, so the whole regression is area the design
gained without gaining any work.

### 8.4 Option (c) - stay at 32 bits and find the bit elsewhere

Four candidates, of which two are dead, one is the answer, and one is a
better answer to a different question.

**(c1) Absorb Arg3 - this works, and it is nearly free.**

`Arg3` is used by exactly **two instructions in the entire ISA**, `v_mad` and
`v_dot4` (section 4.2).  Dropping it repacks the word as:

```
|1f          18|17    13|12     8|7     3|2 1 0|
|    Opcode  8 | Arg0 5 | Arg1 5 | Arg2 5|     |
```

8 + 5 + 5 + 5 + 8 for Mod is **31 bits, with one bit spare**.  Three 5-bit
register fields and the full 8-bit Mod both survive.

The cost is that `v_mad` and `v_dot4` lose their third source.  That cost is
very close to zero because **both are already accumulate forms**: section
4.6 defines them as `v[dst] = v[src0] * v[src1] + v[src2]` and
`v[dst] = v[src2] + sum_k ...`.  Making the accumulator implicitly the
destination - `v[dst] += v[src0] * v[src1]` - preserves the operation exactly
where the destination is the accumulator, which is what both benchmark uses
are.  `axpy16k_w`'s four `v_mad` per chunk compute `y += a*x` into `y`;
they become four two-source `v_mac` with **the same instruction count and the
same cycle count**.  The GEMM kernel uses neither instruction.

What is genuinely lost is the *non-destructive* three-operand form, which
costs one extra `v_mov` wherever a kernel needs the addend to stay live.
Neither benchmark does; a stencil or an FFT butterfly might.

**(c2) Fewer scalar registers - dead, and section 5.2 already proves it.**

Section 5.2's allocation ends "All 16 scalar and all 16 vector registers are
live in the main loop", and the scalar table backs that up with thirteen
named non-temporary values: a loop counter, four fill pointers and bases,
`&C`, `K`, `N`, `8*K`, two LDS read bases, the other buffer's base and the
wave id.  Cutting to 8 SGPRs would force spill and reload to LDS inside the
inner loop of the kernel the machine exists to run.  Rejected on evidence,
not on taste.

**(c3) An implied or aligned quad encoding - solves nothing as posed, but
points at the actual fix.**

As posed this is a misdiagnosis, and saying so is more useful than costing
it: `v_ld16_g`'s Arg0 already uses only 2 of its 4 bits, so tightening its
encoding frees bits *in that one instruction* and does nothing for the field
width every other instruction needs.  The quad rule is a symptom of having 16
registers, not the cause.

Relaxing the alignment so a quad may start anywhere does not help either, and
the arithmetic is worth writing down.  `axpy16k_w` holds 4 VGPRs of `x`, 4 of
`y` and 1 lane-address register.  Double-buffering two chunks needs
`2 x (4 + 4) + 1 = ` **17 registers**.  Not 32 - **seventeen**.  The kernel
misses by exactly one register, which is why it is worth one more look:

> **(c3') Give `v_ld16_g` and `v_st16_g` an implicit lane stride.**  Their
> effective address is truncated down to a multiple of 16, so the low 4 bits
> of the 8-bit `Mod` field are already dead in these two instructions.  Spend
> one of them as a mode bit meaning "lane `l` accesses `s[Arg2] + Mod +
> 16*l`, ignoring Arg1".  The contiguous wide access - overwhelmingly the
> common case, and the only case `axpy` uses - then needs **no address VGPR
> at all**, and the kernel double-buffers in 16 registers with one to spare.

That is a zero-bit, zero-area change that captures the whole 5.5%.  It does
not serve the GEMM fill, whose lane offset is `(lane>>1)*K + (lane&1)*16` and
genuinely needs the VGPR term - but the GEMM fill is not the bottleneck and
does not double-buffer anyway.

The alternative of recomputing the address each iteration instead of holding
it costs 2 instructions on a 22-instruction loop, **9%, to chase 5.5%**.  It
is a losing trade and is recorded here so it is not rediscovered later.

**(c4) A register window or base register - the right idea for a machine this
is not.**

VGPR number = `window_base + Arg`, with the base in an SGPR or in wave state.
The objection is not area, which is one adder, but that it puts a *data*
dependency in the decode stage: the scoreboard tracks physical registers, so
it cannot check a hazard until the base is resolved, and a write to the base
creates a stall against every following vector instruction.  Decode is
currently the simplest part of the design and the part inherited most directly
from `cpu16.v` (section 4.13).  It also destroys static register knowledge in
the assembler and in `.list` output, which is a real loss on a machine whose
debugging story is "read the listing".

Four resident waves already bank the register file; a window adds a second,
software-visible banking scheme on top.  Rejected for a 5.5% prize.

| Option | Section 7.3 | `gpu16-full` area | `gpu4-tiny` | Encoding cost |
|--------|-------------|-------------------|-------------|---------------|
| (a) status quo | baseline | 3.3 mm2 | 12 tiles, $620 | none, but the 5th bit is gone forever |
| (b) 64-bit word + 32 VGPRs | `gemm*` unchanged, `axpy16k_w` **-5.5%** | **4.09 mm2**, 0.39 -> 0.31 GMAC/s/mm2 | **~17 tiles, over the ceiling** | every instruction 2x; scalar half all waste |
| (c1) absorb Arg3 | unchanged | 3.3 mm2 | 12 tiles, $620 | `v_mad`/`v_dot4` become 2-source |
| (c2) fewer SGPRs | **GEMM inner loop spills** | 3.3 mm2 | 12 tiles | rejected |
| (c3') implicit lane stride | `axpy16k_w` **-5.5%** | 3.3 mm2 | 12 tiles, $620 | **one dead Mod bit** |
| (c4) register window | unchanged | +~0 | 12 tiles | new decode-stage hazard class |

### 8.5 Recommendation

**Do (c1) and (c3'), and do not widen the instruction word.**  Concretely:

1. **Repack to 8 / 5 / 5 / 5 / 8 with one spare bit**, absorbing `Arg3`.
   `v_mad` and `v_dot4` become two-source accumulate-into-destination forms,
   renamed `v_mac` and `v_dot4_acc` to make the destructive semantics obvious
   at the call site.
2. **Implement only 16 VGPRs in the first silicon.**  Bit 4 of every register
   field must be written zero and is checked by the assembler.  `gpu4-tiny`
   implements 8.  Nothing in section 7.3, 7.5 or 7.6 changes by a single
   cycle, square micron or dollar.
3. **Add the implicit-lane-stride mode bit to `v_ld16_g` / `v_st16_g`**, which
   is what actually unblocks the `axpy` double-buffering, inside 16 registers,
   for no bits and no area.
4. **Revisit 32 VGPRs only when a benchmark demands it** - at which point the
   encoding already allows it and the decision is a pure area trade, made with
   measurements from tier 2 rather than from this document's estimates.

The reasoning in one line: *the register file, not the encoding, is what 32
registers cost; so buy the encoding now, because it is free, and defer the
register file, because it is not.*

This also disposes of the framing the question arrived in.  "Enlarge the word
to fit the registers" assumes the encoding is the binding constraint.  It is
not - the binding constraint is 0.55 mm2 of flip-flops on a 3.3 mm2 die, and
widening the word adds 0.24 mm2 to that bill rather than removing anything
from it.

### 8.6 What I would have to be wrong about

In rough order of how likely each is to actually bite:

1. **That `v_mad`'s third operand is dead weight.**  This is the real risk in
   (c1) and it is a claim about *future* kernels, which is the weakest kind of
   claim in this document.  Two benchmarks is a thin basis.  If a
   non-destructive three-operand multiply-add turns out to be wanted in an
   inner loop, (c1) costs a `v_mov` per use, and the spare 31st bit will not
   rescue it.  **Cheap insurance: write the stencil or FFT kernel as a paper
   exercise before committing to (c1).**  That is an afternoon and it converts
   the weakest assumption here into a measured one.
2. **That section 7.3's 90.7% matrix utilisation is right.**  The whole
   argument rests on GEMM being matrix-bound and `axpy` being port-bound.
   Both come from the Model-A hand analysis in section 7.2, which section 7.4
   exists precisely to falsify.  If tier 2 shows the GEMM main loop is
   actually limited by fill register pressure, 32 registers stop being worth
   5.5% and this recommendation is wrong.  It is testable before any of it is
   built, which is the point of the ladder.
3. **That the machine stays at 4 waves and int8.**  Sixteen VGPRs is
   comfortable for this workload and would be tight for FP32, where every
   value costs two registers, or for a deeper pipeline needing more in flight.
   Note this failure mode *supports* the recommendation rather than
   undermining it: it is the case where reserving the 5th bit now pays.
4. **That (c3') is implementable as cheaply as claimed.**  The lane-stride
   address generator is a shifter and an adder per lane, but it is a *second*
   address path alongside the three-term one, and it lands in the address
   coalescer - lumped into section 7.5's 0.30 mm2 "decode, scheduler,
   scoreboard, coalescer" line, which is the least itemised number in the
   area table.
5. **That the area estimates are anywhere near right.**  They are
   gate-count-times-density figures and could be off by 2x. But the
   recommendation depends on a *ratio* - a per-instruction tax versus a
   one-time register-file cost - and that ratio is robust to a common-mode
   error in the density anchor.
6. **That program memory is on-chip.**  It is assumed to be, and section 7.5
   never listed it, which is a gap this section closes. If it were off-chip,
   option (b) would get worse, not better: instruction fetch would then
   compete for the pins that section 7.5 already identifies as the binding
   constraint on real silicon.  The recommendation survives being wrong here.

**Deliberately not decided.**  Whether to spend the spare 31st bit at all.  It
is worth more unspent than it is worth as a flag nobody planned, and this
document has already made the mistake once of describing a constraint in one
section without checking it against the numbers in another.
