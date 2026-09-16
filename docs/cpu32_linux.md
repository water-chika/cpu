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

What the three cores, the memories, the tools and the 69 tests are today,
read out of the RTL rather than remembered, because every estimate below is
measured from here.

## 2. The starting point

### 2.1 Candidate A - widen `cpu16.v` a second time

### 2.2 Candidate B - promote the gpu16 scalar unit to `cpu32`

### 2.3 Candidate C - a third core written fresh

### 2.4 Recommendation

Which of the three is cheapest to the *first Linux boot*, not to the first
32-bit `add`, and what the recommendation costs elsewhere in the repo.

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
