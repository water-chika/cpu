# FPGA bring-up plan

**Status: PLAN ONLY.** Nothing here has been run on hardware, and nothing
here has been run through a synthesis tool either. There is no Vivado on the
machine this was written on - no `/opt/Xilinx`, no `/tools/Xilinx` - so every
statement below about synthesis, inference, resources and timing comes from
**reading the RTL**, not from a report. Where a number could only come from a
tool, this document says which tool and which report would produce it rather
than inventing the number.

The board is an AMD/Xilinx FPGA. **The part number is unknown**, the only
connection to it is **USB-JTAG**, and there is **no UART**. That last pair of
facts drives most of section 4: everything that goes in or comes out has to
go through the JTAG chain.

The ordering principle is *board time is scarce, desk time is not*. So the
bulk of this plan (section 2) is work that can be finished before the board is
ever plugged in, and section 3 is the deliberately short list of questions
that a desk cannot answer.

## Contents

1. [What is being brought up](#1-what-is-being-brought-up)
2. [Phase 0 - everything provable at the desk](#2-phase-0---everything-provable-at-the-desk)
3. [The short list that genuinely needs hardware](#3-the-short-list-that-genuinely-needs-hardware)
4. [The on-board phase, in order](#4-the-on-board-phase-in-order)
5. [Troubleshooting](#5-troubleshooting)
6. [Verified locally vs untested](#6-verified-locally-vs-untested)

## 1. What is being brought up

Three machines live in this repo, all synthesisable Verilog:

| Module | What it is | Size |
|--------|-----------|------|
| `cpu8.v` | 8-bit Harvard CPU, `cpu_inst8_data8` | 210 lines |
| `cpu16.v` | 16-bit instruction / 8-bit data CPU, `cpu_inst16_data8` | 323 lines |
| `gpu16.v` | one SIMT wave: fetch, scalar unit, decode, exec mask | 1088 lines |
| `gpu16_cu.v` | the compute unit - 4 waves, shared LDS / global port / matrix unit / barrier | 416 lines |
| `gpu16_vector.v` | 16 lanes, 16 VGPRs and 32 accumulators per lane | 348 lines |
| `gpu16_lds.v` | 8 KiB LDS as 16 independently addressed banks | 86 lines |
| `gpu16_gmem.v` | global memory port, one 64-byte block per cycle | 77 lines |
| `gpu16_matrix.v` | 64 int8 MACs, 16 lanes x 4 | 88 lines |
| `memory.v` | `memory` and `program_memory` - the array primitives | 112 lines |

gpu16 is **fully implemented**, not a stub: the wave, the workgroup, the
vector unit with its accumulator file, the banked LDS, the coalescing global
port and the matrix array all exist and all pass tests. The ISA they
implement is `docs/gpu_isa.md`.

Three properties matter for an FPGA and all three hold today, by reading:

* **Real resets.** Every state element that needs one is written in an
  `always @(posedge clk or posedge reset)` with an explicit reset arm -
  `cpu16.v:163`, `gpu16.v:687`, `gpu16_cu.v:326`, `gpu16_vector.v:212`.
* **No `initial` blocks in the RTL.** The only occurrences of the word are
  comments explaining their absence (`cpu16.v:13`, `cpu8.v:7`,
  `memory.v:6`). Memory arrays are the sole unreset state, which is correct:
  they are filled by `$readmemh` in simulation and are supposed to be filled
  by a loader on hardware. Section 2.2 is about what happens when they are
  not.
* **No delays, no simulation-only constructs** in the synthesisable files;
  `#` delays appear only in the testbenches (`test.v`, `test16.v`,
  `testgpu.v`).

Everything is exercised by **68 CTest tests, all green locally** - 23 of them
gpu16 RTL simulations (`gpu_alu` through `gpu_mma_wg`), 8 CPU RTL
simulations, plus assembler, compiler, oracle, encoding, fuzz and lint tests.
`verilog_lint` (test #17) is `tests/lint_verilog.sh`: it compiles every `.v`
file standalone under `iverilog -Wall` and fails on *any* message at all.

Performance counters already exist in the RTL, in `gpu16_cu.v:312-357`:
`perf_gmem_bytes`, `perf_gmem_trans`, `perf_lds_cycles`, `perf_mma_busy`,
fed back into every wave so that `s_rd_sys` can read them. A cycle count is
not among them; the testbench counts cycles itself, and section 4.6 says what
to do about that on hardware.

### 1.1 What "bring-up" means here, and what it does not

Bringing this up on an FPGA means: the same programs, assembled by the same
assembler, produce the same architectural state, on a device, at a clock the
timing report justifies. It does **not** mean running the section 7 GEMM
benchmarks - section 4.7 explains why the current global memory makes
`gemm64` and larger impossible on hardware without new RTL, and that is a
finding worth having before the board is ordered rather than after.

## 2. Phase 0 - everything provable at the desk

This is the bulk of the plan. None of it needs a board, none of it needs
Vivado, and all of it is cheaper to iterate on than a bitstream.

### 2.1 What the 68 tests already prove

The gpu16 tests run a whole `gpu16_cu` under `iverilog` (`testgpu.v`
instantiates `gpu16_cu`, not a bare wave) and compare wave 0's 16 scalar
registers against a `.expect` file and, where given, all 256 VGPR words
against a `.vexpect` file. They insist the program reach `s_endpgm`; a
program that ran off its end fails even if the registers look right.

| Tests | What is therefore already settled |
|-------|-----------------------------------|
| `gpu_alu`, `gpu_imm`, `gpu_sys` | scalar ALU, immediates, the `s_rd_sys` table |
| `gpu_branch`, `gpu_exec`, `gpu_divergent` | control flow, branch bubbles, the exec mask and reconvergence |
| `gpu_vector`, `gpu_lane` | the 16 lanes, cross-lane reads, `v_readlane` |
| `gpu_mem`, `gpu_global`, `gpu_gstore`, `gpu_gwide`, `gpu_coalesce` | the global port, wide accesses, block coalescing |
| `gpu_lds`, `gpu_bank` | the 16-bank LDS and bank-conflict behaviour |
| `gpu_wg` | four waves, `s_wave_id`, `s_barrier` |
| `gpu_mma` .. `gpu_mma_wg` (7 tests) | the matrix unit, including its exec-mask and zero-accumulate corners |
| `cpu8_*`, `cpu16_*` (8 tests) | both CPUs against hand-written expectations |
| `xcheck_*` (9 tests) | RTL against the C++ simulator, instruction by instruction |
| `c16_fuzz_rtl` | randomly generated C16 programs, compiled and run on RTL |

**This is the part hardware cannot improve on.** Functional correctness of
the RTL is settled by simulation; a device runs the same logic. What a board
can add is only *speed*, *fit* and *the things outside the RTL* - clocking,
reset, the JTAG path. Saying this plainly up front stops the board becoming
an expensive way of re-testing what is already tested.

The one qualification: simulation tests the *pre-synthesis* RTL; hardware
runs what the tools made of it. The gap between those two is the subject of
2.2, and a post-synthesis and post-implementation functional simulation in
Vivado - once a Vivado exists - closes most of that gap without a board.

### 2.2 What a synthesis-style lint would catch - by reading

`tests/lint_verilog.sh` runs `iverilog -Wall`, which checks that the Verilog
is legal and clean; it says nothing about whether the result is *good
hardware*. Reading the RTL with synthesis in mind turns up five things, one
of them fatal. All of them are **desk findings, not tool findings**: no
synthesis run has confirmed any of them, and confirming them is the first
thing to do when a Vivado install exists.

#### (a) The program memory will be optimised away. This is the blocker.

`gpu16.v:156-166` instantiates the program memory as:

```verilog
memory #(.DATA_WIDTH(32), .ADDR_WIDTH(PROGRAM_ADDR_WIDTH)) program (
    .clk(clk), .write_enable(1'b0), .enable(1'b1),
    .address(program_address), .in_data(32'b0), .out_data(Inst));
```

`write_enable` is tied to zero. Inside `memory.v` the only assignment to the
array is guarded by `enable & write_enable`, so on hardware **nothing can
ever write the array** - and with no `initial` block and no `$readmemh`
outside simulation, nothing ever fills it either. A synthesis tool sees an
array that is never written and never initialised. The legal outcome is a
constant; the likely outcome is that `Inst` collapses to zero and takes the
decoder, the ALU and eventually most of the design with it.

In simulation this is invisible, because `testgpu.v` reaches straight into
the hierarchy - `$readmemh(program_file, U0.wg[N].w_inst.program.mem, ...)`
once per wave - and a hierarchical `$readmemh` is not something that survives
synthesis.

Consequence: **a program memory write port is not an optional debug
nicety, it is a precondition for the design existing on a device at all.**
That same port is what section 4.5's loader needs, so the fix and the loader
are one piece of work. The same argument applies to `gpu16_gmem`'s array
(`gpu16_gmem.v:47`), which *is* written by the design so will not be trimmed,
but whose contents at power-up are undefined - every test that passes `+data`
needs that array loaded from outside.

The cheapest shape for the fix, to be designed properly later: a second write
port on the wave's program memory - `memory.v`'s `program_memory` already
demonstrates the two-port pattern for cpu16 - driven by a debug block, with
the four waves' copies written together, since every wave runs the same
program.

#### (b) Every memory in the design is asynchronous-read, so none of it is BRAM

`memory.v` says so in its own header and means it: "Reads are asynchronous...
On an FPGA this maps to distributed RAM rather than to a block RAM." The same
holds for `gpu16_lds.v:66` (`assign out_data[...] = mem[word]`) and
`gpu16_gmem.v:58` (`assign out_block[...] = mem[base | OFFSET]`). Xilinx
BRAM has a registered read port; an array read combinationally cannot be a
BRAM, so Vivado will build LUTRAM instead - silently - and where the port
count defeats LUTRAM it will fall back to registers.

This matters most for the program memory, because of its size. With
`PROGRAM_ADDR_WIDTH = 12` each wave holds 4096 x 32 = **131,072 bits**, and
there are **four waves per compute unit**, so 512 Kbit of asynchronous-read
storage for instruction fetch alone. As LUTRAM at 64 bits per SLICEM LUT
that is order 2,000 LUTs per wave before output multiplexing - call it 10,000
LUTs for a compute unit, which on a small Artix-7 is most of the device.
**Hand-estimated; only a synthesis report can confirm it.**

Note also that `gpu_isa.md` section 7.5 predicts "8 KiB of LDS as 8 BRAM18 in
16 banks". As written the LDS cannot be BRAM at all, for the reason above.
That prediction is already falsified by reading, before any tool runs.

The cut-down is easy and is section 4.3's first lever: the largest
checked-in test program is `gpu_wg.s` at 197 source lines, so
`PROGRAM_ADDR_WIDTH = 8` (256 words, 8 Kbit per wave) holds every test in the
repo with room to spare and cuts instruction storage 16x. It is already a
module parameter that `testgpu.v` passes through, so it costs nothing but a
parameter value.

#### (c) The register and accumulator files may become flip-flops

`gpu16_vector.v:138` declares `reg [31:0] vregs[0:255]` and `:153`
`reg [31:0] accs[0:511]` - 8 Kbit + 16 Kbit per wave, 96 Kbit for a four-wave
compute unit. Most accesses are per-lane with the lane index a `genvar`
constant (`vregs[{arg1, LANE}]`), which is cheap: sixteen 16-deep memories.
But `gpu16_vector.v:190` is

```verilog
assign mat_a = vregs[{mat_areg, mat_row}];
```

with *both* fields dynamic, so one read wants an arbitrary index across all
256 words, and several read ports are live at once (`arg1`, `st_reg`,
`mat_breg`, `mat_idx`). Multi-port asynchronous read of a writable array is
exactly what pushes a synthesiser off LUTRAM and onto registers plus
multiplexers. If all 96 Kbit lands in flops, that alone is comparable to the
whole flop count of a mid-size Artix-7.

That is a *prediction*. The FF row of the first utilisation report, and
whether `vregs`/`accs` appear as RAM or as registers, is the single most
valuable output of the first synthesis run.

#### (d) Asynchronous reset everywhere

All four sequential blocks use `posedge reset` in the sensitivity list.
Asynchronous resets are legal on Xilinx flops but they cost: they block
SRL/DSP/BRAM absorption of adjacent registers, they create a high-fanout
global net, and the *release* must be synchronous to the clock or different
flops leave reset in different cycles. Synchronising the release is
board-side work (section 4.4) and needs no RTL change. Converting to
synchronous reset is a legitimate later experiment, but it is a change to
verified RTL and the 68 tests are the gate on it.

#### (e) What a real synthesis pass would add that reading cannot

Named honestly, because these are the reasons to install Vivado before buying
anything:

* the inferred-primitive report - which arrays became LUTRAM, BRAM or
  registers;
* DSP inference for `gpu16_matrix.v`'s 64 signed 8x8 multiplies. They may
  become 64 DSP48s, 32 packed DSP48s, or plain LUT logic; `gpu_isa.md`
  section 7.5's "32 DSP48E1 slices packing two int8 MACs each" is an
  assumption, and the RTL at `gpu16_matrix.v:78-84` writes each product
  separately and sums four of them combinationally, which is not obviously
  the shape a packing inference wants;
* inferred-latch warnings from the nine `always @*` decode blocks
  (`gpu16.v:433`, `gpu16_cu.v:111`, and the rest) - `iverilog -Wall` does not
  flag inferred latches the way a synthesiser does;
* multi-driver and unconnected-port warnings across the generate-heavy
  `gpu16_cu` wiring;
* the critical-path candidates of section 3.1, with real numbers.

None of that needs a board. All of it needs a tool install, and it should
happen before any hardware is connected.

### 2.3 Dry runs of the loader and capture flow, in simulation

The hardware harness - loader, control registers, result readback - is new
RTL and new host code, and it is exactly the part that has no tests. It
should be written and debugged **entirely in simulation first**, because a
bug in it on hardware is indistinguishable from a bug in the GPU.

The gap it has to close is precise. `testgpu.v` gets programs in and results
out by hierarchical reference, and none of that exists on a device:

| Simulation does | Hardware needs |
|-----------------|----------------|
| `$readmemh(prog, U0.wg[N].w_inst.program.mem)` x4 | a real write port on the program memory, written over JTAG |
| `$readmemh(data, U0.data.mem)` | a real write port into `gpu16_gmem` |
| `reset = 1; #7 reset = 0;` | a reset the host can pulse, released synchronously |
| `while (ran < cycles && U0.halted !== 1)` | `halted` in a status register the host can poll, plus a cycle counter and a timeout |
| `U0.wg[0].w_inst.registers[i]` | a readback path for the 16 scalar registers |
| `U0.wg[0].w_inst.vector.vregs[i]` | a readback path for the 256 VGPR words |
| plusargs `+arg_ptr/+group_x/+group_y/+wave_id/+waves` | writable launch-parameter registers |

The plan:

1. **Write the debug wrapper** - one module owning the address map of
   section 4.5, instantiating `gpu16_cu` and adding the write ports from
   2.2(a). When the debug block is idle it must not change `gpu16_cu`
   behaviour at all, and that is a testable property, not a hope.
2. **Write a second testbench** that drives the wrapper *only through its bus
   port* - no hierarchical references anywhere - loading the program, pulsing
   reset, polling halted, reading the registers back. Then run **the existing
   `.expect` and `.vexpect` files through it**, since the entire point is
   that the two paths agree.
3. **Require both testbenches to pass every gpu test**, as separate CTest
   entries. Any discrepancy is a wrapper bug, caught at the desk for free.
4. **Model the JTAG transport's ordering, not its timing.** The host issues a
   sequence of reads and writes; the simulation harness can execute the same
   sequence from the same script, so the host-side script is debugged before
   it ever meets a cable.
5. **Add a cycle counter and expose the four existing perf counters** through
   the same address map, then check in simulation that they read the values
   `gpu_mma_perf` already asserts. That test is the calibration point: the
   correct counter values are already known and checked in.

The output of Phase 0 is a design that, in simulation, can be loaded, run and
read back exactly the way hardware will do it, with all 68 tests plus a
parallel bus-driven run of the 23 gpu tests green. **Only then is a board
worth connecting.**

## 3. The short list that genuinely needs hardware

Everything in section 2 can be finished at a desk. This is what cannot be,
and it is deliberately short - three items and two footnotes. If a proposed
board experiment is not on this list, it belongs in simulation.

### 3.1 Real Fmax

The design has never been through static timing analysis, so **no clock
frequency in this repository is justified by anything**. `gpu_isa.md` section
7.5 assumes 100 MHz on an Artix-7; that is an assumption inherited from a
deleted `memory_ramb18e1.v` wrapper, not a measurement.

Reading the RTL gives candidate critical paths, which is what the first
`report_timing` should be checked against:

1. **Fetch through execute in one cycle.** `PC` -> asynchronous LUTRAM read
   of the program memory (`gpu16.v:153-166`) -> opcode/field decode
   (`gpu16.v:178-183`) -> the `always @*` decode blocks -> 32-bit scalar ALU
   -> register write, all inside one clock period. There is no fetch/decode
   pipeline register. This is the most likely critical path in the whole
   design, and it gets *worse* with a bigger `PROGRAM_ADDR_WIDTH` because the
   LUTRAM output multiplexer grows.
2. **The matrix unit.** `gpu16_matrix.v:59-85`: asynchronous read of `vregs`
   and `accs`, four signed 8x8 multiplies, a 4-input adder tree, a 32-bit
   accumulate, written back to `accs` - 16 lanes wide, all combinational
   between two edges. If the multiplies land in DSP48s without pipeline
   registers this is slow; if they land in LUTs it is slower.
3. **The LDS crossbar.** Address computation -> sixteen per-bank row selects
   -> asynchronous 512-bit read (`gpu16_lds.v:63-71`) -> lane routing -> VGPR
   write.
4. **The global port.** 512-bit asynchronous read out of `gpu16_gmem` with
   byte-enable merging, in the consuming cycle.
5. **The four-wave arbiter.** `gpu16_cu.v:219` documents a fixed-priority
   grant chain across four waves, combinational, feeding the memory ports in
   the same cycle it resolves.

Only a tool can rank these. The deliverable is a number: the highest clock
for which `report_timing_summary` shows WNS >= 0, on a named part.

### 3.2 Actual resource fit

Section 2.2 predicts that instruction storage and the vector/accumulator
files dominate, and that neither becomes BRAM. Those are predictions from
reading. The utilisation report settles them, and it settles the prior
question of whether a four-wave `gpu16_cu` fits the board at all. Note that
synthesis alone is enough for both 3.1 and 3.2 - **this item needs a Vivado,
not a board.** It is listed here only because it must be answered before a
bitstream is worth making.

### 3.3 Real JTAG behaviour

Cable enumeration, chain scan, the device IDCODE, configuration succeeding,
`INIT_B`/`DONE` behaviour, whether the board's JTAG survives being driven at
the default TCK frequency, and how slow a Tcl-driven AXI transaction really
is. None of this can be simulated, because none of it is in the RTL.

### 3.4 Two things that look like they need hardware but do not

* **Functional correctness.** Section 2.1. The device runs the same logic
  the simulator ran.
* **Cycle counts.** Same argument: this design has no external memory, no
  DRAM refresh, no interrupts and no asynchronous inputs, so a kernel takes
  *exactly* the same number of cycles on hardware as in simulation. A
  hardware cycle count that differs from the simulated one is not a
  measurement, it is a bug - which makes it a superb self-check, and section
  4.6 uses it as one.

## 4. The on-board phase, in order

Each step below says what it produces and, where relevant, what would have
caught its failure at the desk. Do not start this section until Phase 0 is
green.

### 4.1 Identify the device, and write down what you find

The part number is unknown, and everything downstream - part-specific
constraints, resource limits, IO standards - depends on it. So the first
session produces a record, not a bitstream.

With Vivado's hardware manager (or `xsdb`, or `openFPGALoader` for a
read-only chain scan), connect and record:

| What | Where it comes from | Why it matters |
|------|--------------------|----------------|
| Cable type and serial | `get_hw_targets`, `get_hw_devices` | identifies the board family; Digilent vs FTDI vs platform cable changes the driver needed |
| Number of devices in the chain | chain scan | a two-device chain (FPGA + flash/PROM) needs the right device selected |
| **IDCODE** | `get_property IDCODE [current_hw_device]` | this *is* the part identification |
| Part name | `get_property PART [current_hw_device]` | what every later tool invocation needs |
| Device family, speed grade | derived from the part | speed grade changes Fmax by 10-20% |
| Maximum TCK the cable negotiates | `get_property PARAM.FREQUENCY [current_hw_target]` | sets how slow the loader of 4.5 will be |
| Anything silkscreened on the board | eyes | clock frequency, board revision, oscillator part number |

Two derived facts must be found before anything else: **the clock input pin
and its frequency**, and **a usable reset input** (pushbutton or none). With
no UART and no board documentation, the oscillator frequency may have to come
from the oscillator's own markings.

The output of 4.1 is a short note in this repo recording the part, so that
the next person does not repeat the archaeology.

*Nothing in simulation could have caught a wrong part number, which is
exactly why this step is first.*

### 4.2 Resource and fit estimate, per module

Estimates from reading, for one `gpu16_cu` in the default configuration
(4 waves, `PROGRAM_ADDR_WIDTH = 12`, `DATA_INDEX_WIDTH = 10`, 8 KiB LDS).
**Every number in this table is hand-derived and none has been checked by a
tool.** The right-hand column is what to compare against once one has.

| Module | State | Hand estimate | Confirm with |
|--------|-------|---------------|--------------|
| program memory x4 (`memory.v` via `gpu16.v:156`) | 4 x 131 Kbit, async read, never written | ~2,000 LUTs/wave, ~8-10k LUTs total *or the whole thing trimmed away*, see 2.2(a) | utilisation report, LUTRAM row |
| `vregs` x4 (`gpu16_vector.v:138`) | 4 x 8 Kbit | LUTRAM if the tool can, ~32k FFs if it cannot | primitive inference report |
| `accs` x4 (`gpu16_vector.v:153`) | 4 x 16 Kbit | as above, ~64k FFs worst case | primitive inference report |
| `gpu16_lds` | 64 Kbit, 16 banks x 128 x 32, async read | ~1,000 LUTs of LUTRAM; **not** the 8 BRAM18 section 7.5 predicts | utilisation report, BRAM row = 0 |
| `gpu16_gmem` | 32 Kbit (4 KiB), 16 x 64 x 32 effective | ~500 LUTs of LUTRAM | utilisation report |
| `gpu16_matrix` | none (combinational) | 64 signed 8x8 MACs: 64 DSP48, 32 packed DSP48, or ~4-5k LUTs | DSP row; check against 7.5's claim of 32 |
| scalar+decode logic x4 (`gpu16.v`) | ~100 FFs/wave | ~2-3k LUTs/wave | utilisation report |
| `gpu16_cu` arbiters, counters, barrier | ~200 FFs | ~500 LUTs | utilisation report |

The headline: **instruction storage and the vector/accumulator files are the
fit risk, not the matrix unit.** The matrix array is the part that sounds
expensive and is not - 64 int8 MACs is small - while 512 Kbit of
asynchronous-read instruction memory for four copies of a 200-line program is
the part that sounds free and is not.

### 4.3 The documented cut-down, if gpu16 does not fit

Five levers, cheapest first. **Rule: no bitstream is built for a
configuration that has not first passed the 68 tests in simulation with those
same parameter values.** Every lever below is a parameter change, so
re-validating it costs one `ctest` run.

| # | Lever | Change | Cost | Tests lost |
|---|-------|--------|------|-----------|
| L1 | Shrink program memory | `PROGRAM_ADDR_WIDTH` 12 -> 8 (256 words) | none - the largest test program, `gpu_wg.s`, is 197 source lines | none |
| L2 | Shrink global memory | `DATA_INDEX_WIDTH` 10 -> 8 (1 KiB) | halves the address space the tests can use | any test whose `.data32` exceeds it - check by re-running |
| L3 | Fewer waves | build 2, or 1, instead of 4 | loses the workgroup | `gpu_wg`, `gpu_mma_wg`; `s_barrier` becomes untested on hardware |
| L4 | Smaller LDS | `gpu16_lds` `ROWS` 128 -> 32 (2 KiB) | fewer/smaller tiles | any test that addresses past 2 KiB - re-run to find out |
| L5 | Narrower matrix unit | 64 MACs -> 16 (one per lane), four cycles per `mma_i8` | changes `mma` timing, so `perf_mma_busy` and the Model-A 16-cycle occupancy no longer hold | `gpu_mma_perf` at minimum; the other `gpu_mma_*` should still pass |

**L1 should be taken unconditionally**, fit or no fit: it is free, it removes
the largest single resource consumer, and it shortens the critical path of
3.1(1).

L3 needs one piece of work that is not a parameter today: `gpu16_cu.v`
builds its four waves in a `generate` loop while the `waves` input `[2:0]`
only chooses how many of them *launch*. Reducing the number of waves that
*exist* means making the generate bound a parameter. That is a small change,
but it is a change to tested RTL, so it is gated on the 68 tests.

A sixth option exists and should be named: **build a single `gpu16` wave with
no compute unit around it** as the very first bitstream. It drops the LDS,
the global port, the matrix unit and the arbiter, so it is a fraction of the
size, and it is enough to prove clocking, reset, configuration and the
loader. The gpu tests that need none of those - `gpu_alu`, `gpu_imm`,
`gpu_branch`, `gpu_sys`, `gpu_vector`, `gpu_lane`, `gpu_exec`,
`gpu_divergent` - are the first hardware test set. Bisecting bring-up this
way means the first failure has a small number of possible causes.

Even smaller, if the first bitstream will not configure at all: **`cpu8.v`**.
It is 210 lines, it has three passing tests, and it exercises exactly the
things that are in doubt at that point - clock, reset, configuration, loader
- and none of the things that are not.

### 4.4 Clocking and reset

**Clocking.** The design has no MMCM, no PLL and no clock-domain crossing:
one clock, one domain, everything on `posedge clk`. So the constraint set is
small - a `create_clock` on the board oscillator input, the standard IO
constraint for that pin, and nothing else - but the *frequency* is the open
question of 3.1.

The sequence that avoids wasting board time:

1. Constrain at something certainly achievable. If the oscillator is
   100 MHz, derive a slow clock (25 MHz, or 12.5 MHz) through a Clocking
   Wizard, or divide it in fabric, and constrain that. **Bring up at the slow
   clock.** A design that fails at 100 MHz and works at 25 MHz teaches
   nothing if 25 MHz was never tried.
2. Once tests pass, raise the constraint in steps and re-implement, watching
   WNS. Fmax is the last frequency that closes, and the honest report is
   `1 / (T - WNS)` at the tightest passing constraint together with the path
   that limits it.
3. Record the limiting path against section 3.1's candidate list. If it is
   the fetch path, L1 and a fetch pipeline register are the fixes; if it is
   the matrix unit, a pipeline stage inside `gpu16_matrix` is - but that
   changes `mma` latency and therefore Model-A, so it is an ISA-visible
   change, not a tuning knob.

**Reset.** `reset` is asynchronous and active high (`gpu16.v:687` and the
rest). On a device it needs:

* a source - a pushbutton, or a power-on reset counter if there is no button,
  or a bit in the debug wrapper so the host can pulse it over JTAG. **The
  host-writable bit is the important one**, because the test loop in 4.6
  resets between every test program;
* **asynchronous assert, synchronous release** - a two-flop synchroniser on
  the deassertion edge, so every flop leaves reset in the same cycle;
* correct polarity. A pushbutton is usually active low.

*What simulation would have caught:* nothing about reset polarity or release
timing - `testgpu.v` drives `reset = 1; #7 reset = 0;` with no synchroniser
at all, and an unsynchronised release is invisible in an event simulator. The
reset synchroniser is therefore untestable at the desk and belongs on the
short list in spirit, if not on the critical path.
