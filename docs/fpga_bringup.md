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
