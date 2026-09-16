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

Each item is marked **PREREQUISITE** (the kernel does not boot without it) or
**OPTIONAL** (a fuller configuration wants it; a first boot does not), with
what exists today beside it. Where the mark depends on the configuration, it
says which configuration, because "Linux needs an MMU" is false and "Linux
needs no MMU" is misleading.

The target this section is written against is deliberately the *cheapest one
that is still honestly Linux*: **32-bit, uniprocessor, nommu, initramfs, no
swap, no networking, a serial console and a shell.** Every relaxation is
named where it is taken.

### 3.1 A 32-bit word and a real register file

**PREREQUISITE.** The kernel's `long`, its pointers and its `unsigned long`
bitmaps are all the machine word, and the vast majority of the tree assumes
that word is at least 32 bits. This is not negotiable and not emulable.

**Register count is a separate PREREQUISITE, and cpu16's 8 fails it.** The
hard floor is set by the compiler, not by the kernel: a C compiler needs
enough registers to hold a stack pointer, a frame pointer, a link register, a
few argument registers, some callee-saved registers and a couple of
scratch. Every 32-bit Linux architecture that shipped has 16 or 32 general
registers - m68k and SuperH have 16, ARM has 16, RISC-V, MIPS and PowerPC
have 32. **16 is the floor, 32 is comfortable.**

*Today:* gpu16's scalar unit has 16 x 32-bit. That meets the floor. cpu16's
8 x 8-bit fails on both axes. Widening to 32 registers later costs one bit in
three operand fields, which the 32-bit instruction word does not have spare -
so **this is a decision to take before writing any code, not after**, and it
is the single most consequential encoding choice in the plan.
`gpu_isa.md` section 8 is a worked precedent for exactly this argument.

### 3.2 Byte, halfword and word load/store, and the alignment rules

**PREREQUISITE, all three widths, signed and unsigned for the narrow two.**
The kernel is full of `char`, `u8`, `u16`, packed structures and byte-wise
string functions. A machine that can only load a 32-bit word makes every
`char` access a shift-and-mask sequence the compiler has to synthesise;
possible, and ruinous both for code size and for the compiler port.

**Alignment.** Two self-consistent positions, either acceptable:

1. Natural alignment required; a misaligned access raises a precise
   exception. This is what a first implementation should do. It is what
   most RISC machines did, Linux copes, and `get_unaligned()` exists for the
   handful of places that need it.
2. Hardware handles misaligned access. More logic, no kernel benefit worth
   the gates at this scale. **OPTIONAL and not recommended.**

Position 1 is only coherent *once exceptions exist* (3.3) - until then a
misaligned access has nowhere to go. That ordering constraint shapes
section 4.

*Today:* cpu16 has byte load/store into 256 bytes. gpu16's scalar side has
**word load only and no store at all**, and it is block-shaped. The whole
scalar load/store unit is new work under either candidate of section 2, and
it is the first real piece of RTL the plan asks for.

### 3.3 Exceptions and interrupts

**PREREQUISITE, and this is the largest single gap in the repository.**
Neither cpu16 nor gpu16 has any of it: `grep -i "interrupt\|exception\|trap"`
over every `.v` file in this repo returns nothing. `gpu_isa.md` 4.3 even
notes the absence approvingly - a carry flag would be "a piece of
architectural state with its own save/restore question the moment anything
resembling an interrupt appears".

The minimum, itemised, because "add exceptions" is not one task:

| Piece | Mark | What it is |
|---|---|---|
| A trap-taking mechanism | PREREQUISITE | on a fault or interrupt, hardware saves the PC, records a cause, and redirects the PC to a vector |
| Saved-PC state | PREREQUISITE | an `EPC`-equivalent, readable and writable |
| A cause and a fault-address register | PREREQUISITE | the handler has to know *what* and, for a memory fault, *where* |
| A trap vector base | PREREQUISITE | writable, so the kernel installs its own handlers |
| A return-from-trap instruction | PREREQUISITE | restores PC and the interrupt-enable state **atomically**; doing it in two instructions is a race and a classic new-port bug |
| A global interrupt-enable bit | PREREQUISITE | this is also how a UP kernel gets its atomics for free - see 3.8 |
| At least one external interrupt input | PREREQUISITE | the timer needs it; the console wants it |
| A system-call instruction | PREREQUISITE | user code must be able to enter the kernel deliberately |
| Precise exceptions | PREREQUISITE | the faulting instruction must not have half-committed. Cheap here: cpu16/gpu16 are effectively single-issue in-order with a short pipeline, so this is nearly free - and would not be on anything deeper |
| Nested/prioritised interrupts, an interrupt controller with many lines | OPTIONAL | one line and software demux is enough to boot |
| Vectored (per-cause) entry points | OPTIONAL | one entry point and a cause dispatch is enough |

`s_rd_sys` is architecturally the right shape for the state above - a
numbered read of non-GPR state - but it is **read-only** and its values are
hardwired. A real CSR mechanism needs a matching write and a defined set of
writable numbers. That is a small extension of something already designed,
which is the practical payoff of the section 2 recommendation.

### 3.4 Privilege levels

**PREREQUISITE for a system you would trust; OPTIONAL for the first boot,
with a caveat.**

Honest version: Linux can be brought up on a machine with one privilege level
- that is what nommu Linux effectively is on several architectures. Userspace
runs with the same powers as the kernel, any process can scribble on the
kernel, and `fork()` does not exist. That is a genuine, historically shipped
configuration (uClinux and its descendants), and it is a legitimate **first**
target because it removes an entire axis of debugging.

What is *not* optional even then is the **system-call trap** of 3.3: user
code must have a defined way to enter the kernel. The privilege level is what
makes that boundary enforceable; the trap is what makes it exist.

The recommendation is to design two levels into the state model from the
start (one status bit, a previous-privilege bit saved on trap) and implement
the enforcement later. Retrofitting privilege into an ISA after the ABI is
fixed is far more expensive than reserving the bit.

### 3.5 A timer

**PREREQUISITE.** Linux needs a *clocksource* (a monotonically increasing
counter it can read) and a *clockevent* (a programmable interrupt at a chosen
future time, or periodically). Without the second there is no scheduler tick,
no timeouts, and no preemption; the kernel's own boot sequence calibrates
against it and will hang.

Minimum viable device: a 32-bit (better, 64-bit) free-running counter at a
known frequency, a comparator register, and an interrupt when they match.
This is perhaps 60 lines of Verilog and one of the cheapest PREREQUISITEs on
the list.

*Today:* gpu16 has `perf_cycles`, a free-running cycle counter readable
through `s_rd_sys`. That is half of the clocksource already, and is a fair
illustration of why section 2 recommends what it recommends.

### 3.6 A console

**PREREQUISITE in practice.** Formally the kernel boots without one; in
practice a bring-up with no console is a bring-up where a failure is
indistinguishable from a hang, and everything in this project's method -
`.expect` files, cross-checks, `docs/fpga_bringup.md`'s whole troubleshooting
section - depends on being able to see what happened.

* **Output only, memory-mapped TX register, polled**: enough for `earlycon`
  and for every boot message. PREREQUISITE. Perhaps 40 lines.
* **Input (RX), interrupt-driven**: needed for a shell. Strictly OPTIONAL for
  "it booted", required for "I used it".
* A 16550-compatible register layout: OPTIONAL, but worth it - an existing
  kernel driver instead of a written one.

### 3.7 Virtual memory: page tables, or a nommu build

**The MMU is OPTIONAL, and taking the option is the single largest saving in
this plan.**

Linux has supported `!CONFIG_MMU` for two decades, and several architectures
(m68k, SuperH, ARM, ARC, RISC-V, Xtensa) carry live nommu ports. What it
costs, stated so the decision is informed:

* **no `fork()`** - only `vfork()` and `clone()` with shared memory. Every
  userspace program must be written or built to cope. BusyBox does.
* **no demand paging, no swap, no `mmap()` of a file privately** - the whole
  program is resident.
* **no memory protection** - a userspace bug corrupts the kernel.
* **binaries must be position-independent in a specific way**: bFLT or
  FDPIC-ELF, which means the toolchain has to emit them (section 5).
* **fragmentation becomes a real failure mode**, since allocations must be
  physically contiguous.

None of those stop a shell prompt appearing. They do stop it being a general
purpose system, which is why the MMU is not dropped from the plan, only
deferred.

**If the MMU is later built**, it is PREREQUISITE-sized work in its own
right: a TLB, a page-table walk (hardware or a software-refill trap), fault
reporting with a faulting address, TLB-invalidate instructions, an
address-space identifier or a full flush on context switch, and a kernel/user
address split. Realistically this is the second-largest item in the whole
plan after the compiler. A software-refill TLB (MIPS's approach) is the
cheaper form and is the one to choose: less hardware, and the walk lives in
kernel C where it can be debugged.

### 3.8 Atomics

**OPTIONAL on a uniprocessor, PREREQUISITE the moment there are two cores.**

This is the item people over-build. On a UP kernel with no preemption inside
critical sections, every atomic operation can be implemented as
*disable interrupts, do it, restore interrupts* - and that is exactly what
`ARCH_ATOMIC` fallbacks and several real ports do. So the interrupt-enable
bit of 3.3 is not just an interrupt feature: **it is the atomics story.**

What is still needed even on UP:

* a way to disable and restore interrupts atomically (part of 3.3);
* compiler and kernel agreement that there is no SMP (`CONFIG_SMP=n`).

A load-reserved/store-conditional pair or a compare-and-swap instruction is
the right thing to add *before* a second core, and a waste of gates before
that. Mark it as scheduled work, not as a gap.

### 3.9 Boot protocol and device tree

**PREREQUISITE, though less of it than it first appears.**

What must exist:

* **a defined entry state**: where the kernel image is in memory, what the PC
  is at release from reset, and which register (if any) holds a pointer to
  the hardware description;
* **a way to get several megabytes into memory before release**: today this
  repo's loader writes one word per cycle with reset held high
  (`cpu16.v`'s `prog_load_*`, `gpu16_cu`'s `prog_load_*`). At one word per
  JTAG-clocked cycle, a 4 MiB image is not a plausible load path - see 6.3;
* **a hardware description**: a flattened device tree is the modern answer
  and a new architecture should use it rather than invent a boot parameter
  block. It must describe at minimum the memory range, the timer frequency,
  the interrupt controller and the console;
* **an initramfs**, which is how a nommu system gets a root filesystem
  without a block driver. This can be linked into the kernel image itself
  (`CONFIG_INITRAMFS_SOURCE`), which removes the need for any storage device
  at all. **Do this**; it deletes an entire class of work.

OPTIONAL: a bootloader. With the image and the DTB linked together and
written by the loader, there is nothing for one to do.

### 3.10 The non-hardware prerequisite nobody costs

**PREREQUISITE, and it is not RTL at all: `arch/cpu32/` inside the kernel
tree.** A new Linux architecture port is, at minimum, its own: entry/trap
assembly, context switch, `thread_info` and `pt_regs` layout, signal delivery,
syscall table and wrappers, memory init, IRQ chip driver, timer driver,
`Kconfig`/`Makefile` wiring, `uapi` headers, and a set of atomic/bitop/barrier
headers. Existing minimal ports (RISC-V's original merge, ARC, openrisc) land
in the region of **10,000 to 20,000 lines**, much of it adapted rather than
invented, but all of it needing to be right.

This is stated here rather than in section 8 because it belongs on the
requirements list: it is as much a prerequisite for booting as the trap
mechanism is, and it is larger than all the RTL in this plan combined.

### 3.11 The itemised table

| # | Requirement | Mark | Exists today? |
|---|---|---|---|
| 3.1 | 32-bit word and address | PREREQUISITE | gpu16 scalar: yes. cpu16: no |
| 3.1 | >= 16 general registers | PREREQUISITE | gpu16: 16, at the floor. cpu16: 8, fails |
| 3.1 | 32 registers | OPTIONAL (but decide *now*) | no |
| 3.2 | byte/halfword/word load and store, signed and unsigned | PREREQUISITE | **no** - cpu16 is byte-only; gpu16 scalar is word-load-only, no store |
| 3.2 | trap on misaligned access | PREREQUISITE (given 3.3) | no |
| 3.2 | hardware misalignment fixup | OPTIONAL, not recommended | no |
| 3.3 | precise trap, EPC, cause, vector base, return-from-trap | PREREQUISITE | **no, none of it** |
| 3.3 | global interrupt enable | PREREQUISITE | no |
| 3.3 | >= 1 external interrupt input | PREREQUISITE | no |
| 3.3 | system-call instruction | PREREQUISITE | no |
| 3.3 | interrupt controller, vectored entry, nesting | OPTIONAL | no |
| 3.4 | two privilege levels | PREREQUISITE for a real system; OPTIONAL for first boot | no |
| 3.5 | clocksource (free-running counter) | PREREQUISITE | **partly** - `perf_cycles` via `s_rd_sys` |
| 3.5 | clockevent (comparator + interrupt) | PREREQUISITE | no |
| 3.6 | polled TX console | PREREQUISITE in practice | no |
| 3.6 | RX, interrupt-driven | OPTIONAL (required for a shell) | no |
| 3.7 | MMU, TLB, page tables, faults, invalidation | OPTIONAL (nommu first); PREREQUISITE for `fork()` and protection | no |
| 3.8 | atomic RMW or LR/SC instructions | OPTIONAL on UP; PREREQUISITE on SMP | no |
| 3.9 | defined entry state and hardware description (FDT) | PREREQUISITE | no |
| 3.9 | a loader that can move megabytes | PREREQUISITE | **no** - one word per cycle, see 6.3 |
| 3.9 | initramfs linked into the image | PREREQUISITE (avoids needing storage) | n/a - kernel config |
| 3.9 | bootloader | OPTIONAL | no |
| 3.10 | `arch/cpu32/` in the kernel tree | PREREQUISITE | no |
| - | multiply | OPTIONAL (libgcc can) | yes, both |
| - | divide | OPTIONAL (libgcc can) | cpu16 yes; gpu16 deliberately not |
| - | carry flag / add-with-carry | OPTIONAL | cpu16 yes; gpu16 reserved, unimplemented |
| - | caches, coherency | OPTIONAL at this scale | no, and no need |
| - | idle/wait-for-interrupt | OPTIONAL | no |

The shape of that table is the finding: **eleven hardware PREREQUISITEs are
entirely absent, and every one of them is in sections 3.2, 3.3, 3.5, 3.6 and
3.9 - the load/store unit, the trap architecture, the timer, the console and
the boot path. None of them are about being 32 bits wide.** Widening the
data path is the part of this project that is already mostly done.

## 4. The staged sequence

### 4.1 How a stage is judged done

Three rules, taken from how this repository already works rather than
invented for this document:

1. **A stage ends with a CTest that fails before it and passes after it.**
   `docs/fpga_bringup.md` 4.3's rule - "no bitstream is built for a
   configuration that has not first passed the tests" - generalises: no stage
   is claimed without a test that would have caught its absence. The
   `gpu_gfar` test in commit 308421e is the model: it was checked to *fail*
   against the old configuration before it was checked in.
2. **Existing tests do not change.** All 69 stay green, byte for byte,
   through every stage. Where a stage makes that impossible the plan says so
   in advance (only S0 comes close, and it must not).
3. **Where a C++ model exists, the RTL is cross-checked against it.** The
   `xcheck_*` family and `c16_fuzz_rtl` are worth more than any `.expect`
   file, and a `cpu32_sim.cpp` beside `cpu16_sim.cpp` should be built as the
   ISA grows, not afterwards.

**The verdict function has to change partway through**, and it is better to
know that now. `tests/run_test.sh` runs N cycles and diffs the final register
file. That is right for an instruction and meaningless for a boot. From S5
the verdict becomes *"the bytes the UART transmitted match this expected
transcript"*, which is a new testbench and a new runner script alongside the
old ones - not a change to them, and not RTL.

### 4.2 The stages

Estimates are **for one person working evenings and weekends**, which is what
this repository visibly is. They assume no hardware is involved until S12.
All of them are predictions (section 9).

---

**S0 - Split the scalar unit out of `gpu16.v`.**
Produce `cpu32.v` holding the fetch, decode, scalar ALU, branch and
system-register logic; `gpu16.v` instantiates it and keeps the vector,
matrix, LDS, exec-mask and global-port logic.
*Pass criterion:* all 69 tests green, **zero `.expect` files touched**, and
`verilog_lint` clean on the new file. This is precisely the derisking
argument `gpu_isa.md` 4.13 already made for the synthesis clean-up.
*Effort:* **1-2 weekends.** Pure refactor, well fenced by 26 gpu tests.

---

**S1 - A byte-addressed 32-bit PC, and a narrow memory port.**
Replace the 16-bit word-addressed PC with a 32-bit byte-addressed one (so
`s_addpc`, `s_call` and the `_i` branches change units), and give the core a
word-wide instruction and data port with **`ready`/`valid`** rather than the
64-byte block port.
*Pass criterion:* a new `cpu32_branch` test - a program that branches
backwards and forwards past 64 KiB - plus the 69 unchanged. The stall path
gets its own test: a testbench memory that deasserts `ready` on a fixed
pattern, with identical final registers to one that never stalls.
*Effort:* **2-4 weekends.** The ready/valid stall is the part that will take
longer than expected; it is the first time anything in this repository can be
told "not yet" (commit 308421e says exactly this about the GPU's port).

---

**S2 - The scalar load/store unit.**
`lb`, `lbu`, `lh`, `lhu`, `lw`, `sb`, `sh`, `sw` with register+immediate
addressing, and a misalignment detection signal that goes nowhere yet.
*Pass criterion:* `cpu32_ldst`, covering each width, both sign extensions,
and store-then-load at every byte offset within a word; plus an `xcheck`
against `cpu32_sim.cpp`.
*Effort:* **2-4 weekends.** This is the first genuinely new datapath - see
1.1: gpu16 has no scalar store at all.

---

**S3 - The trap architecture.** The big one before the toolchain.
Writable system registers (a real CSR space, generalising `s_rd_sys`),
`EPC`, cause, trap-value, vector base, a status word with an
interrupt-enable bit and a saved copy, a `trap-return` instruction, a
`syscall` instruction, and traps raised by illegal instruction and by the
misalignment signal S2 left dangling.
*Pass criterion:* `cpu32_trap` - a program that installs a handler, then
deliberately executes an illegal instruction, a misaligned load and a
syscall, and whose handler records each cause in a register before returning.
The test passes only if all three causes appear in the right order and the
program then reaches its end normally. A second test proves the
enable/disable bit by taking a trap with interrupts masked and checking it is
*not* taken.
*Effort:* **1-2 months.** Not because any one piece is hard, but because this
is where an ISA acquires state that everything else must then save, restore
and agree about, and where the bugs are non-local. Budget for getting the
trap-return atomicity wrong once.

---

**S4 - Timer and interrupts.**
A free-running counter (extend `perf_cycles`), a comparator, an interrupt
output, and an external interrupt input reaching the S3 trap mechanism.
*Pass criterion:* `cpu32_timer` - enable interrupts, arm the comparator for
`now + K`, spin; the handler increments a register and re-arms. After N
cycles the register holds the arithmetically predicted count. That number is
checkable by hand, which is what makes it a good test.
*Effort:* **2-3 weekends.** Cheap, and it is what makes S3 provably real.

---

**S5 - A UART, and the transcript harness.**
A polled memory-mapped TX register, then RX. Alongside it: `run_console_test.sh`
and a testbench that collects transmitted bytes into a file and diffs them
against a `.expect` transcript.
*Pass criterion:* `cpu32_hello` - a program that writes a fixed string and
halts; the transcript matches exactly.
*Effort:* **1-2 weekends** for the UART, **1 weekend** for the harness. Low
risk, high leverage: everything after this is debuggable.

---

**S6 - Memory, in simulation, at Linux scale.**
A simulation memory of tens of MiB behind the S1 ready/valid port, and a load
path that fills it from a file in one go rather than a word per cycle.
*Pass criterion:* a `cpu32_far` test in the spirit of `gpu_gfar` - write two
patterns megabytes apart, read both back - which must be verified to **fail**
against a small memory before it is checked in.
*Effort:* **1-2 weekends.** Also the point at which to move simulation from
`iverilog` to **Verilator** for speed; see 4.3. That migration is tooling, not
RTL, and the iverilog path stays as the lint and reference.

---

**S7 - Two privilege levels.**
A current-privilege bit, a saved-previous-privilege bit, privileged
instructions and CSRs faulting in user mode, and a defined user/supervisor
split of the address space.
*Pass criterion:* `cpu32_priv` - user-mode code attempts a privileged CSR
write and a `trap-return`, and both must trap with the right cause; the
handler returns to user mode and the program completes.
*Effort:* **2-4 weekends**, *if* the bits were reserved in S3. Months if they
were not - which is the whole argument of 3.4.

---

**S8 - The compiler.** See section 5. An LLVM backend for cpu32, or a GCC
port.
*Pass criterion:* the compiler builds a small C program; the program runs on
the RTL through the S5 transcript harness and prints what it should. Then the
real one: **it builds `newlib` or a small libc, and then BusyBox.**
*Effort:* **4-12 months.** This is the largest single item in the plan after
the kernel port, and section 5 argues it cannot be avoided by growing `c16`.

---

**S9 - `arch/cpu32/`, nommu.** See 3.10.
*Pass criterion:* staged, because "it booted" is not one event. In order:
(a) the entry point is reached and `earlycon` prints one character;
(b) `start_kernel` reaches the console handover and prints the banner;
(c) the timer tick is counted and `Calibrating delay loop` completes;
(d) the kernel panics with `No working init found` - **this is a success**,
    it means the whole kernel ran;
(e) `init` from an initramfs runs;
(f) a shell prompt, and `echo hello` works.
Each of (a)-(f) is a checked-in transcript `.expect` file and therefore a
CTest.
*Effort:* **6-18 months.** The range is wide and honestly so: how much can be
adapted from an existing minimal port dominates it.

---

**S10 - The MMU.** Software-refill TLB, page-table format, fault reporting,
invalidation, and `CONFIG_MMU=y`.
*Pass criterion:* the S9 (f) transcript, with `fork()` working - the simplest
honest demonstration being a shell script that pipes one command into
another, which nommu cannot do.
*Effort:* **3-9 months.**

---

**S11 - SMP, atomics, a second core.** Everything 3.8 defers.
*Effort:* **months**, and out of scope until S10 is done.

**S12 - Hardware.** Follow `docs/fpga_bringup.md`, whose phases apply
unchanged; the new constraint is section 6's memory, which is a board
question, not an RTL one.

### 4.3 What is weeks and what is months

| Stage | Scale | Why |
|---|---|---|
| S0, S4, S5, S6 | **weekends** | refactor, or a small well-understood peripheral with a hand-checkable pass criterion |
| S1, S2, S7 | **weeks** | new datapath, but local, and testable one instruction at a time |
| S3 | **1-2 months** | new *architectural state*, whose bugs are non-local |
| S8 | **4-12 months** | a compiler backend is a project, not a task |
| S9 | **6-18 months** | a kernel port is a bigger project |
| S10 | **3-9 months** | as above, with the hardware half attached |

The shape of that table is the real finding of this plan: **S0 to S7 - all of
the RTL, the entire CPU - is on the order of four to six months of evenings,
and S8 to S10 is on the order of one to three years.** The machine is the
cheap part. Everything above it is not.

**A warning about simulation speed, marked as a prediction (P4).** A nommu
boot to a shell is plausibly 10^8 to 10^9 clock cycles. `iverilog` is an
interpreter; on a design this size it is likely in the 10^4-10^5 cycles/second
range, which puts one boot attempt somewhere between *hours and weeks*. That
is not a debugging loop. Verilator compiles to C++ and should be 100-1000x
faster, bringing a boot to minutes. **S6 should adopt Verilator, and the
iverilog path should be kept as `verilog_lint` and as the reference for the
existing 69 tests.** None of these numbers have been measured here.

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
