# cpu32 - widening the ISA until Linux boots on it

**Status: skeleton.** Headings and one line of intent each. Sections are
filled in and pushed one at a time; anything still one line has not been
thought through yet, and should not be quoted.

**Scope: plan only.** No RTL and no toolchain code changes anywhere in this
document's commits. The existing 69 CTest tests are not touched.

---

## Contents

1. [Where this repository actually stands](#1-where-this-repository-actually-stands)
2. [The starting point: widen `cpu16` again, or promote the gpu16 scalar unit?](#2-the-starting-point)
3. [What Linux actually requires](#3-what-linux-actually-requires)
4. [The staged sequence](#4-the-staged-sequence)
5. [Toolchain consequences](#5-toolchain-consequences)
6. [Area, memory and the board](#6-area-memory-and-the-board)
7. [The RISC-V question, argued rather than dismissed](#7-the-risc-v-question)
8. [What this costs, and what could stop it](#8-what-this-costs-and-what-could-stop-it)
9. [Predictions, stated so they can be falsified](#9-predictions)

---

## 1. Where this repository actually stands

Every estimate below is measured from here, so this section is read out of
the RTL rather than remembered.

### 1.1 The three cores

**`cpu8.v`** - the first machine, 8-bit everything. Not a candidate for
anything below; it exists as the smallest thing that can be put on an FPGA
to prove a clock and a loader (`docs/fpga_bringup.md` 4.3).

**`cpu16.v`**, 355 lines, and the module is called `cpu_inst16_data8`, which
is the honest name: **the "16" is the instruction word, not the data path.**

| | `cpu16.v` today |
|---|---|
| instruction word | 16 bit, 7-bit opcode at `[15:9]`, three 3-bit fields |
| register file | `reg [7:0] registers[7:0]` - 8 registers, **8 bits each** |
| PC (`IP`) | 8 bit; 256 instruction words, and that is the whole program |
| data memory | `memory` with `ADDR_WIDTH = 8`, `DATA_WIDTH = 8` - **256 bytes**, byte accesses only |
| immediates | `imm3 << imm_shift`, i.e. one of a handful of values; anything else is built up with `imm`/`imm_s` chains |
| architectural state outside the regfile | one `carry` bit |
| control flow | opcodes 32-36, branch to a *register*; `addpc` (19) to build a target; no call, no return, no stack pointer |
| memory instructions | 64-67 (`ld`, `st`, `st` zero, read-modify-write) plus 68/69 (`ld_p`/`st_p`, which read and write its own instruction memory) |
| exceptions, interrupts, privilege, timer, MMU, atomics | **none - not one of them, not even a stub** |

The `stall`/`stall_active` pair is a one-cycle branch bubble. There is a
loader port on each memory so a host can write a program in with `reset`
held high, which is the path the FPGA plan uses.

**`gpu16.v`**, 1203 lines, one wave of the SIMT machine in
`docs/gpu_isa.md`. Its *scalar* unit is the interesting part here, because
`docs/gpu_isa.md` 6.3 decision 5 and 4.13 settle explicitly that it **is a
widened `cpu16.v`**, and the RTL says so in its own header comment:

```
registers       8 x 8 bit   ->  16 x 32 bit
select fields   3 bits      ->  4 bits
PC              8 bit       ->  16 bit, word addressed
data address    8 bit       ->  24 bit
immediate       8 bit       ->  16 bit, sign extended
instruction     16 bit      ->  32 bit, 8 bit opcode
```

It also has, beyond cpu16: `s_addi`/`s_muli`/`s_andi`/`s_xori`/`s_ori` with a
sign-extended 16-bit immediate, `s_imm`/`s_immh` so any 32-bit constant is two
instructions, variable shifts (`s_shl`/`s_shr`/`s_sar`), `s_min`/`s_max`,
PC-relative branches (`s_bnz_i`, `s_bz_i`, `s_b_i`), **`s_call` with a link
register**, and `s_rd_sys` reading a numbered system register including a
free-running cycle counter. It does *not* have `adc`/`sbb` (numbers reserved,
deliberately unimplemented - `gpu_isa.md` 4.3) or `div` (number reserved).

What its memory path is, precisely, matters a great deal in section 2:
the only scalar memory instruction in the entire ISA is **`s_ld_g` (0x85),
"load one 32-bit scalar word"**. There is no scalar store, no scalar byte or
halfword access, and no scalar-visible address space other than the 24-bit
global one reached through a workgroup-shared 64-byte-per-cycle port.

**`gpu16_cu.v`**, 473 lines - four waves, a shared LDS, a barrier,
round-robin issue, port arbiters, workgroup performance counters, and since
commit 308421e an `EXTERNAL_GMEM` parameter that brings the 18-bit block
index out of the module.

### 1.2 The memories

`memory.v` holds three things: `memory` and `program_memory`, both
**asynchronous-read** 256-entry arrays (distributed RAM, deliberately - see
the header comment; converting them would change cpu8's and cpu16's timing,
which nine cross-check tests pin cycle for cycle), and `block_memory`, the
registered-read form the large arrays use. `gpu16_gmem.v` is the 64-byte-wide
global array, `gpu16_lds.v` the 16-bank scratchpad.

### 1.3 The tools

`asm` (cpu8), `asm16` (cpu16) and `asm_gpu16` are three `main()`s over one
shared pipeline: the ISA description lives in `asm_kernel.hpp` and the
encoder is `asm_encode_statement<asm_isa>`, so a fourth ISA is a fourth
description rather than a fourth assembler. `c16` compiles a small C-like
language **whose only type is an 8-bit unsigned `int`** (`docs/c16.md`: "8
bit unsigned values only. There is one type, `int`, and it is a byte.
Arithmetic wraps."), into at most 256 instruction words and 256 bytes of
data. `c16_verify` is an independent interpreter used as a differential
oracle, and `cpu16_sim.cpp` is a C++ model cross-checked against the RTL.

### 1.4 The test harness, and what it can and cannot judge

69 CTest tests. Structurally they are four kinds:

* **encoder agreement** (`backends_*`) - serial, threaded and HIP backends
  must emit identical bytes;
* **differential** (`c16_differential*`, `oracle_*`, `xcheck_*`,
  `c16_fuzz_rtl`) - compiler against interpreter, RTL against C++ model;
* **lint** (`verilog_lint`) - every `.v` compiles alone under `iverilog -Wall`
  with zero messages;
* **simulation** (`cpu8_*`, `cpu16_*`, `gpu_*`) - `tests/run_test.sh`
  assembles a program, runs it under `vvp` **for a fixed cycle budget**, and
  compares the **final register values** against a checked-in `.expect` file.

That last mechanism is the one to keep in mind for section 4. "Run N cycles,
then diff the register file" is an excellent way to test an instruction and a
useless way to test a kernel boot: a boot is not a number of registers, and
it is not 300 cycles. The harness scales fine through the first two thirds of
the plan and then needs a different verdict function - a console transcript
compared against an expected one. That is a new testbench, not new RTL, and
it is costed in section 4.

---

## 2. The starting point

The question is not "which core is closer to 32 bits" - that has an obvious
answer - but **which core is closer to running Linux**, which is a different
question, because a Linux-capable core is mostly made of things *neither*
core has.

### 2.1 Candidate A - widen `cpu16.v` a second time

Take `cpu_inst16_data8` and grow the data path to 32 bits, the register file
to 16 or 32 entries, the PC and the data address to 32 bits, and redesign the
instruction word (16 bits cannot name two 32-entry sources and a destination
with an opcode, so the word grows to 32 anyway).

**What survives:** the control skeleton, the opcode numbering, five branch
opcodes, and the five cpu16 simulation tests, which keep passing because
`cpu16.v` itself is untouched.

**What it is really:** every row of the 4.13 table changes. When all six
widths change and the instruction word doubles, what is inherited is *a
style*, not a module - about forty lines of control logic and a decode table,
which is exactly the accounting `gpu_isa.md` 4.13 already makes for the
identical exercise. The honest description of candidate A is "write a new
core in cpu16's style", and note that **this work has already been done once,
in `gpu16.v`.** Doing it a second time produces a second 32-bit widening of
the same 16-bit core, diverging from the first.

### 2.2 Candidate B - promote the gpu16 scalar unit to `cpu32`

Lift the scalar half of `gpu16.v` into a standalone `cpu32.v`: 16 x 32-bit
registers, 16-bit PC, 32-bit instruction word, 8-bit opcode with 240 free
encodings, a full immediate story, `s_call`, and `s_rd_sys`.

**What genuinely comes for free** (this is the strong part of the case):

* a 32-bit ALU that is already written, linted and exercised by `gpu_alu`,
  `gpu_imm`, `gpu_branch` and `gpu_sys`;
* an **8-bit opcode field with most of it unused.** This is worth more than
  it sounds. Everything in section 3 - traps, `mret`-equivalents, CSR access,
  fences, atomics, TLB maintenance - is *new instructions*, and cpu16's
  7-bit-opcode 16-bit word has nowhere to put an immediate for them.
  `gpu_isa.md` 4.3-4.10 occupies roughly 0x00-0x35 and 0x80-0xa3; 0x36-0x7f
  and 0xa4-0xff are free, which is over 150 encodings;
* a 16-bit sign-extended immediate, which is what makes trap vectors,
  page-table walks and struct offsets expressible at all;
* `s_call` and a link register, i.e. the beginnings of a calling convention;
* an assembler that already exists (`asm_gpu16`) and a numbered
  system-register mechanism (`s_rd_sys`) that is *architecturally the right
  shape for CSRs* - it already reads one of a numbered set of non-GPR state.

**What does not come for free, and must be said plainly:**

* **There is no scalar store.** `s_ld_g` loads; nothing scalar writes memory.
  A CPU needs load *and* store at byte, halfword and word width. So the
  entire scalar memory path - the part that matters most for a CPU - is work
  in both candidates, not inherited in either.
* The memory port it would inherit is the wrong shape: 64 bytes per cycle,
  aligned, block-indexed, workgroup-arbitrated, no ready/valid. A CPU wants a
  narrow word port that can stall. Extracting a scalar core means **replacing
  that port**, not keeping it.
* The PC is 16 bits and word-addressed. A Linux kernel image is megabytes;
  this becomes a 32-bit byte-addressed PC, which also breaks `s_addpc`,
  `s_call` and every `_i` branch's "word offset" definition.
* No carry flag (`s_adc`/`s_sbb` are deliberately unimplemented). Not fatal -
  a 32-bit machine rarely needs multi-word adds - but 64-bit arithmetic in the
  kernel then costs a compare-based sequence.
* Splitting the scalar unit out of `gpu16.v` is a refactor of a module with
  **26 passing gpu tests** attached to it. That is the good kind of risk
  (well-tested), but it is not zero, and every one of those tests is about a
  *wave*, not about a CPU.

### 2.3 Candidate C - a third core written fresh

Ignore both and write `cpu32.v` from scratch with a Linux-shaped ISA from
line one: 32 registers, trap architecture designed in rather than bolted on,
byte-addressed PC, a proper load/store unit.

**For:** none of the compromises above; the ISA can be designed once against
section 3's checklist instead of being retrofitted twice.
**Against:** it throws away the family argument that is most of the value of
this repository - one mental model, one assembler structure, one set of
debugging habits across cpu8, cpu16, gpu16 - and it starts with **zero**
passing tests, which is the thing everything else in this repo has been
careful to avoid.

### 2.4 Recommendation

**Take candidate B: promote the gpu16 scalar unit to `cpu32.v`.** Concretely,
factor the scalar half of `gpu16.v` into a `cpu32.v` that `gpu16.v` then
instantiates or mirrors, and grow *that* toward Linux.

The reasoning, in order of weight:

1. **The expensive part of this project is not the width - it is sections 3.3
   to 3.9**, none of which either core has. Measured against that, candidate A
   and candidate B differ by about forty lines of control logic. What
   distinguishes them is what is left over to *build on*: an 8-bit opcode
   space with 150 free encodings, a 16-bit immediate, and a numbered
   system-register mechanism. Candidate A would have to invent all three
   before it could write its first trap instruction - and inventing them is
   precisely how it would end up re-deriving gpu16's encoding.
2. **The work is already done once and should not be done twice.** Widening
   cpu16 to 32 bits is a solved problem in this repository, with a document
   section justifying every choice and tests holding it down. A second,
   divergent widening would leave the repo with two incompatible 32-bit
   descendants of one 16-bit core, and `gpu_isa.md` 4.3's careful
   opcode-number alignment would become meaningless.
3. **The family story gets stronger, not weaker.** cpu8 -> cpu16 -> {cpu32,
   gpu16 as a SIMT sibling of cpu32} is a cleaner lineage than what exists
   today, and it means the scalar ALU has one implementation, one assembler
   description and one set of tests serving both machines.
4. It starts with passing tests. `gpu_alu`, `gpu_imm`, `gpu_branch` and
   `gpu_sys` are, as of today, a scalar-core regression suite that nobody has
   noticed is one.

**What the recommendation costs, stated up front.** Three things, none
hidden:

* **`gpu16.v` gets refactored.** If the scalar unit becomes a shared module,
  gpu16 instantiates it, and the 26 gpu tests must still pass unchanged. If
  instead `cpu32.v` is a *copy* that then diverges, the two drift and
  `gpu_isa.md` 4.13 becomes a historical note. The first is more work and is
  the right choice; say so explicitly before starting, because the second is
  what happens by default.
* **The ISAs will diverge anyway, and that is fine if it is deliberate.**
  `gpu_isa.md` 4.13 already establishes the rule: *alignment means the numbers
  never disagree, not that both machines implement the same set.* cpu32 will
  implement `div`, `adc`/`sbb`, byte/halfword load-store and a trap block that
  gpu16 will never want; gpu16 keeps the vector, matrix, LDS and exec-mask
  blocks cpu32 will never want. As long as no opcode number means two
  different things, the family holds.
* **The 16-bit PC and the block-shaped memory port both have to go.** These
  are the two inherited pieces that are actively wrong for a CPU, and they
  should be replaced in stage 1 rather than carried.

*One prediction, flagged as such (section 9, P1): the scalar/vector split of
`gpu16.v` is a few-hundred-line refactor of a 1203-line module, not a rewrite.
Nothing has been attempted, so this is a reading, not a measurement.*

## 3. What Linux actually requires

Every item marked PREREQUISITE (the kernel will not boot without it) or
OPTIONAL (nice, or needed only by a fuller configuration), with what the
repository has today beside it.

### 3.1 A 32-bit word and a real register file

### 3.2 Byte, halfword and word load/store, and the alignment rules

### 3.3 Exceptions and interrupts

### 3.4 Privilege levels

### 3.5 A timer

### 3.6 A console

### 3.7 Virtual memory: an MMU with page tables, or a nommu build

### 3.8 Atomics

### 3.9 Boot protocol and device tree

### 3.10 The itemised table

## 4. The staged sequence

Stages S0..Sn, each one independently testable in the existing
iverilog + CTest harness, each with a stated pass criterion and a stated
unit of time - weeks or months.

### 4.1 How a stage is judged done

### 4.2 The stages

### 4.3 What is weeks and what is months

## 5. Toolchain consequences

### 5.1 `asm16`, `asm_gpu16` and the shared encoder

### 5.2 `c16` - and why it is not the compiler a userspace needs

### 5.3 The real answer: a gcc or llvm backend

### 5.4 The rest of the chain: binutils, libc, init

## 6. Area, memory and the board

### 6.1 What the core itself costs, against `docs/fpga_bringup.md` 4.2

### 6.2 The memory requirement, and why it is the binding constraint

### 6.3 The missing DDR controller and the missing ready/valid

## 7. The RISC-V question

Stated fairly, in a section of its own: what adopting RV32 would buy, what it
would cost, and under which goal each answer wins.

## 8. What this costs, and what could stop it

A total effort estimate with its assumptions exposed, and the specific things
that would end the project rather than merely delay it.

## 9. Predictions

Everything above that is a guess, collected in one place and labelled, so a
later reader can check it rather than inherit it.
