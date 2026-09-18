# Water's CPU

The repo contains an ISA definition and a verilog implementation. 

## Verilog implementation

It is simulated and tested  with ```iverilog``` simulator.

## Building and testing

The assemblers are built with CMake, and the simulation tests are driven by
CTest:

```
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

If ```hipcc``` is on the system, GPU backends for the assembler and the
compiler are built as well; if it is not, configuring prints ```HIP not
found, building without the GPU backends``` and everything else builds and
tests exactly the same.  ROCm is never required.

Each test assembles a program from source, runs it on the verilog CPU under
```iverilog```, and compares the final register values against a checked in
```tests/*.expect``` file (```xx``` means "do not care").  A test fails if the
assembler rejects the program, if the CPU decodes an unknown opcode because
the program ran off its end, or if any register holds an unexpected value.
Nothing is generated ahead of time, so a fresh clone can run the tests
straight away.

| Test | Program | Checks |
|------|---------|--------|
| backends_cpu8_hex, backends_cpu8_bin, backends_cpu16_hex, backends_cpu16_bin | generated | the serial, multi core and GPU backends assemble the same program into identical bytes |
| verilog_lint | every ```*.v``` | each verilog source compiles on its own under ```iverilog -Wall``` without a single message |
| cpu8_sum | tests/cpu8_sum.s | 8 bit CPU sums 1..8 out of data memory into r2 |
| cpu8_sum_list | cpu8_asm/sum.s | 8 bit CPU sums the whole of data.list (1..16) into r2 |
| cpu8_label | tests/cpu8_label.s | 8 bit assembler resolves a label at address 75 and the CPU branches there |
| cpu8_ldp | tests/cpu8_ldp.s | 8 bit CPU reads one of its own instructions with ld_p, ors a bit into it, writes it back with st_p and runs it |
| cpu16_sum | tests/cpu16_sum.s | 16 bit CPU sums 1..8 out of data memory into r2 |
| cpu16_count | cpu16_asm/test.s | 16 bit CPU counts to 4 and branches |
| cpu16_label | tests/cpu16_label.s | 16 bit assembler resolves a label at address 75 and the CPU branches there |
| cpu16_adc | tests/cpu16_adc.s | 16 bit CPU carries between bytes through adc and sbb |
| cpu16_ldp | tests/cpu16_ldp.s | 16 bit CPU rewrites one of its own instructions with st_p and reads it back with ld_p |
| backends_c16 | generated | the compiler's serial, multi core and GPU backends agree byte for byte, and its text path assembles to exactly the words its binary path emits |
| c16_arith | tests/c16_arith.c16 | compiled arithmetic and bit operations |
| c16_control | tests/c16_control.c16 | compiled while, if/else, break and continue |
| c16_compare | tests/c16_compare.c16 | every comparison operator, as a value rather than only a branch |
| c16_functions | tests/c16_functions.c16 | calls, parameters, globals and a call nested inside another call's argument |
| c16_spill | tests/c16_spill.c16 | an expression ten deep, so the value stack spills out of the registers |
| c16_memory | tests/c16_memory.c16 | peek and poke against the data memory the testbench loads |
| c16_collatz | tests/c16_collatz.c16 | the longest Collatz chain below 16 - an answer you cannot read off the source |

Each ```c16_*``` simulation test compiles its program down **both** of the
compiler's output paths, assembles the text one with ```asm16```, and diffs
the machine words before it simulates anything.  The paths disagreeing is a
failure even if the program would have run correctly.

To watch a program execute, run the simulation by hand and add ```+trace```:

```
./build/asm16 --hex --sep_with_line < tests/cpu16_sum.s > /tmp/program.list
iverilog -I . -o /tmp/sim16 test16.v
vvp /tmp/sim16 +program=/tmp/program.list +data=tests/sum.data \
    +expect=tests/cpu16_sum.expect +cycles=300 +trace
```

```+program_words=<n>``` and ```+data_words=<n>``` are optional and only stop
```$readmemh``` warning that the file is shorter than the whole memory.

A program still halts by branching to its own address, but that address is
now written as a label rather than built by hand out of an immediate and a
shift.

## Instruction Set Architecture - 8 Bit

Instruction is 8 bit width.

```
|7 6 5 4 3 2 1 0 |
| Opcode  | Arg  |
```

There are 8 registers that is 8 bit width.

There is a 3 bit register src1/dst1.

There are instructions to read/write IP (instruction pointer) register.

Instruction memory and data memory is separated but there are instructions to load/store data.

### Instructions

Opcode is 5 bit width. Arg is 3 bit width.

With 5 bit opcode, there are 32 instructions ( 2^5 == 32 ).

#### Data process

Signed integer instructions uses 2's complement representation.

Instruction field arg encodes src0/dst0 or imm or shift_imm.

| Op  | Opcode |binary| Description |
|-----|--------|------|-------------|
| and |   0    | 00000| bitwise and |
| or  |   1    | 00001| bitwise or  |
| not |   2    | 00010| bitwise not |
| xor |   3    | 00011| bitwise xor |
| add |   4    | 00100| addition    |
| sub |   5    | 00101| subtract    |
| neg |   6    | 00110| negate      |
| mul |   7    | 00111| multiply    |
| div |   8    | 01000| divide      |
| mov |   9    | 01001| move src1 to dst0 |
| mov0|   10   | 01010| move src0 to dst1 |
| imm |   11   | 01011| move imm to dst1  |
| shl |   12   | 01100| shift left imm times|
| shr |   13   | 01101| shift right imm times|

#### Condition

Condition determine if instruction run. Instruction do not run if condition is 0 (except set conditon with 1).

| Op            | Opcode | Description |
|---------------|--------|-------------|
| condition_nz  |   14   | set condition to src0 not zero |
| condition_z   |   15   | sot condition to src0 is zero     |
| condition_lz  |   16   | set condition to src0 less than zero |
| condition_gz  |   17   | set condition to src0 greater than zero |
| condition_1   |   18(0)| set condition to 1 |

#### Branch

Branch condition compare argument with 0 (zero).

Instruction field arg encodes register containing branch address.

| Op  | Opcode | Description |
|-----|--------|-------------|
| b   |   18(1)| branch      |

#### Data transfer

Instruction field arg encodes register containing memory address.

| Op  | Opcode | Description |
|-----|--------|-------------|
| ld  |   24   | load from data memory |
| st  |   25   | store to data memory  |
| cl  |   26   | clear data memory     |
| swap|   27   | swap register and data memory |
| ld_p|   28   | load from program memory |
| st_p|   29   | store to program memory  |

The address comes from the one address register that ```set_data_address```
loads; the opcode says which of the two memories it applies to.  A program
word here is 8 bits, which is exactly one register, so - unlike ```cpu16.v```,
whose 16 bit word makes ```ld_p```/```st_p``` take a half select as well -
```ld_p``` and ```st_p``` move a whole instruction at a time and take only the
register.  The instruction memory has a second port for them, so the fetch
never has to give its own port up, and a byte stored over an instruction is
seen by the fetch in the same cycle.

#### State control

Set processor state

| Op            | Opcode | Description |
|---------------|--------|-------------|
| set_b_target  |   19   | set branch target |
| set_data_address | 20  | set data address  |
| set_src1_dst1 |   31   | set src1 and dst1 |

## Assembler

There is also a simple assembler that implemented by simple string map and a shift operation.

It read an op and an arg seperated by space, like below:

```
imm 1
mov r1
shl 5
mov r7
imm 1
add r1
mov0 r7
mov r2
mov0 r1
sub r2
imm 4
mov r3
mov0 r2
bnz r3
```

### Label Parse

Both assemblers resolve labels in two passes, so a label may be used before it
is defined.

A **label definition** is a token ending in ```:```.  It may be on a line of
its own or in front of an instruction, and it names the address of the next
instruction:

```
loop:
add r1 r4 r1
```

A label is **used** through the one pseudo instruction, ```la```:

```
la <dst> <label>
```

which loads the 8 bit address of ```<label>``` into register ```<dst>```.
That is what a branch needs, because on both CPUs the branch target lives in
a register rather than in the instruction.  A typical program is now:

```
la r6 loop
la r7 halt

loop:
...
bnz r5 r6 0

halt:
b 0 r7 0
```

```la``` expands to a fixed number of real instructions whatever the address
is - 3 on the 16 bit CPU, 10 on the 8 bit one - so the first pass can place
every label without having to resolve anything, and no address is ever out of
reach.

On the 16 bit CPU the expansion is one ```imm``` and two ```imm_s```, one per
3 bit group of the address.  The 8 bit CPU has no or-with-immediate, so there
```la``` folds the address together 3 bits at a time through whichever
register ```set_src1_dst1``` last named.  That register is therefore a
scratch: it is clobbered, it must be set before the first ```la```, and it
must not be the destination.  The assembler tracks it and refuses the program
otherwise rather than emitting something that quietly does the wrong thing.

Defining a label twice, using an undefined label, and a program that does not
fit in 256 instructions are all hard errors.

### Variables To Register

Not implemented.

This library or executable will translate variables to registers or memories.

Its statement contain 4 components seperated with space, like below:

```
add v0 v1 v2
```

Last component is result variable.

Branches opcode is below:

```
be
bne
b
bg
bl
```

### How the assembler runs

Assembling a file is a pipeline of five passes.  Four of them treat lines as
independent work, and only the small middle part has to look at the program in
order:

| Pass | Work | Order |
|------|------|-------|
| split | find where every line starts and ends | independent per byte block |
| classify | lex one line, parse it, decide its opcode and arguments | **independent per line** |
| scan | give every statement an address and collect the labels | chunked prefix sum, then an ordered insert per label |
| resolve | check each statement and look its label up | independent per line, with the scratch register carried between chunks by a prefix scan |
| encode | turn a statement into its words and write them out | **independent per line** |

Nothing in the pipeline appends to a shared buffer.  A statement's output
offset follows from its address alone, so every line writes into a slice of
the output that no other line touches - which is what makes the last pass
runnable anywhere, including on a GPU.

All of the per line work lives in ```asm_kernel.hpp```, which is written so
that it compiles both as ordinary host C++ and as HIP device code.  The three
backends run the *same* source for the per line stages, so agreeing on the
output bytes is a property of the structure rather than something the backends
are trusted to do; ```asm_bench --check``` asserts it anyway, and CTest runs
that.

Backend choice is made through the environment rather than the command line,
so the tools' interface and output are exactly what they always were:

```
ASM_BACKEND=serial|threads|hip|auto    # default auto
ASM_THREADS=N                          # default: hardware concurrency
```

```auto``` picks the threaded backend only once the input is at least two
megabytes.  That is not caution, it is measured: see below.

### Benchmark

```
cmake --build build --target bench     # cpu16, 2M lines
cmake --build build --target bench8     # cpu8
./build/asm_bench --isa 16 --lines 2000000 --repeat 5 [--format hex|bin] [--threads N] [--seed S]
```

It generates a synthetic program from a seeded xorshift, so a run is
reproducible and two runs are comparable, then assembles it with each backend
and reports lines/sec, MB/sec and the speedup over serial, plus where the time
went.  It also compares the output bytes of all three backends and fails if
they differ.

The generated program is larger than the CPU's 256 word program memory, so the
benchmark - and only the benchmark - raises that one limit.  Everything else
about the assembly is what the real tools do.

Measured on a 24 thread host with a Radeon RX 9070 XT (gfx1201, 32 CUs), cpu16,
hex output, best of five:

| lines | source | serial | threads (24) | HIP | 
|-------|--------|--------|--------------|-----|
| 1 000 | 18 KiB | 0.03 ms | 1.14 ms (0.03x) | 0.19 ms (0.17x) |
| 10 000 | 176 KiB | 0.42 ms | 2.54 ms (0.16x) | 1.79 ms (0.23x) |
| 100 000 | 1.7 MiB | 4.56 ms | 4.32 ms (1.06x) | 4.33 ms (1.05x) |
| 1 000 000 | 17.6 MiB | 49.8 ms | 9.33 ms (5.34x) | 8.98 ms (5.55x) |
| 2 000 000 | 35.2 MiB | 111.5 ms | 20.5 ms (5.44x) | 22.4 ms (4.99x) |

Three things worth saying plainly about those numbers:

* **Parallelism does not pay on small inputs.** At a thousand lines the
  threaded backend is thirty times *slower* than the serial one, because each
  parallel pass starts and joins its threads and the whole file is assembled
  in less time than that takes.  Break even is around a hundred thousand
  lines.  Real programs for this CPU are at most 256 instructions, so the
  tools stay serial in practice, and ```auto``` is what makes that happen.
* **The GPU is not the win.** With the host stages given the same cores in
  both columns, the only difference between the ```threads``` and ```hip```
  rows is where the per line work happens, and the two are within noise of
  each other - the GPU classify is about 7.5 ms against the CPU's 6.0 ms at
  two million lines.  Copying the source over PCIe and the results back costs
  about as much as the work is worth, because the work per line is a few dozen
  bytes of comparisons.  This is a real answer, not a tuning failure: the
  problem is memory bound, and the GPU's advantage is arithmetic.
* **The ceiling is the ordered part.** Inserting labels is the one thing that
  must happen in program order.  Moving the re-lexing and hashing of the label
  names into the parallel pass, and replacing ```std::unordered_map``` with a
  table sized up front, took that pass from 11.5 ms to about 2 ms and the
  overall speedup from 3.5x to 5.4x.  What is left of it, plus the serial
  fix up of the chunked prefix sums, is what stops 24 cores reaching 24x.

## Instruction Set Architecture - 16 Bit Instruction & 8 Bit Registers

Instruction is 16 bit width.  Every instruction has the same shape: a 7 bit
opcode and three 3 bit argument fields.

```
|f e d c b a 9|8 7 6|5 4 3|2 1 0|
|   Opcode    | Arg0| Arg1| Arg2|
```

The assembler always takes all three arguments, so a source line is always
```<op> <arg0> <arg1> <arg2>```.  What the fields mean depends on the
instruction:

| Instructions | Arg0 | Arg1 | Arg2 |
|--------------|------|------|------|
| and or xor add sub mul div | src0 | src1 | dst |
| not neg mov  | src0 | unused | dst |
| shl shr srl srr sar | src0 | shift amount | dst |
| imm imm_s add_ip | immediate | shift amount | dst |
| bnz bz blz bgz | register compared with zero | register holding the branch target | unused |
| b            | unused | register holding the branch target | unused |
| ld           | unused | register holding the address | dst |
| st cl swap   | src0 | register holding the address | dst |
| ld_p         | half | register holding the address | dst |
| st_p         | src0 | register holding the address | half |

The immediate is only 3 bits wide, so ```imm``` loads ```arg0 << arg1``` and
```imm_s``` ors ```arg0 << arg1``` into the destination register.  Any 8 bit
constant is built from an ```imm``` followed by as many ```imm_s``` as it
needs, for example 12 is ```imm 1 3 r7``` then ```imm_s 4 0 r7```.

Lines starting with ```#``` are comments, and blank lines are ignored.  An
unknown opcode, a bad argument or an argument that does not fit in 3 bits is
a hard error rather than something silently encoded.

There are 8 registers that is 8 bit width.

There are instructions to read/write IP (instruction pointer) register.

Instruction memory and data memory is separated but there are instructions to load/store data.

### Instructions

Opcode is 7 bit width. Arg is 3 bit width.

With 7 bit opcode, there are 128 instructions ( 2^7 == 128 ).

#### Data process

Signed integer instructions uses 2's complement representation.

| Op  | Opcode | binary | Description |
|-----|--------|--------|-------------|
| and |   0    | 0000000| bitwise and |
| or  |   1    | 0000001| bitwise or  |
| not |   2    | 0000010| bitwise not |
| xor |   3    | 0000011| bitwise xor |
| add |   4    | 0000100| addition    |
| adc |   5    | 0000101| addition with carry in |
| sub |   6    | 0000110| subtract    |
| sbb |   7    | 0000111| subtract with borrow in |
| neg |   8    | 0001000| negate      |
| mul |   9    | 0001001| multiply    |
| div |   10   | 0001010| divide      |
| mov |   11   | 0001011| move        |
| imm |   12   | 0001100| move imm to reg|
| imm_s|   13  | 0001101| combine shifted imm and reg to reg|
| shl |   14   | 0001110| shift left imm times|
| shr |   15   | 0001111| shift right imm times|
| srl |   16   | 0010000| shift rotate left imm times|
| srr |   17   | 0010001| shift rotate right imm times|
| sar |   18   | 0010010| shift arithmetic right imm times|
| add_ip| 19   | 0010011| add (ip+1) with imm to reg |

#### Carry flag

There is one bit of processor state outside the register file: the **carry
flag**.  It is a single bit, it is 0 at reset, and it behaves like this:

| Instruction | What it does to the carry flag |
|-------------|--------------------------------|
| ```add``` ```adc``` | writes the carry out of bit 7 of the addition |
| ```sub``` ```sbb``` | writes the borrow out of bit 7 of the subtraction |
| every other instruction | leaves it alone |

and like this:

| Instruction | What it does with the carry flag |
|-------------|----------------------------------|
| ```adc``` | adds it in: ```dst = src0 + src1 + carry``` |
| ```sbb``` | takes it out: ```dst = src0 - src1 - carry``` |
| every other instruction | ignores it |

Nothing else disturbs the flag, so a multi byte add is one ```add``` on the
lowest byte followed by one ```adc``` per byte above it, and a multi byte
subtract is one ```sub``` followed by one ```sbb``` per byte.  There is no
instruction that reads or writes the flag directly; a program that wants to
know whether an addition carried adds the carry into a zeroed register with
```adc```.

#### Branch

Branch condition compare argument with 0 (zero).

Instruction field arg encodes register containing branch address.

| Op  | Opcode | Description |
|-----|--------|-------------|
| bnz |   32   | branch if not zero |
| bz  |   33   | branch if zero     |
| b   |   34   | branch always      |
| blz |   35   | branch if less than zero |
| bgz |   36   | branch if greater than zero |

branch relative to ip is implemented by add_ip instruction and branch instructions.

#### Data transfer

Instruction field arg encodes register containing memory address.

| Op  | Opcode | Description |
|-----|--------|-------------|
| ld  |   64   | load from data memory |
| st  |   65   | store to data memory  |
| cl  |   66   | clear data memory     |
| swap|   67   | swap register and data memory |
| ld_p|   68   | load a byte from program memory |
| st_p|   69   | store a byte to program memory  |

Program memory is 16 bits wide and a register is 8 bits, so ```ld_p``` and
```st_p``` move **one half of a program word** at a time.  Which half is
chosen by an argument, written as 0 for the low byte and 1 for the high byte:

```
ld_p <half> <address register> <dst>
st_p <src0> <address register> <half>
```

The half sits in Arg0 for the load and in Arg2 for the store, because those
are the fields the two instructions have left over.

```cpu16.v``` gives the program memory a second port for this, so the
instruction fetch never has to stand aside.  A store is visible to the fetch
from the next time that word is fetched, which is what makes a program able to
rewrite itself; ```tests/cpu16_ldp.s``` does exactly that.

## c16, a small C like compiler

```c16``` compiles a small C like language - ```int``` variables, arithmetic,
comparisons, ```if```, ```while```, and functions - to cpu16 machine code.

```
build/c16 --asm  < program.c16                 # readable cpu16 assembly
build/c16 --hex --sep_with_line < program.c16  # machine words, directly
```

It has two output paths and they are required to agree byte for byte.  The
**text path** writes ordinary assembly that this repository's own ```asm16```
assembles unmodified, for reading and debugging.  The **binary path** goes
straight to encoded machine words, reusing the assembler's own per item
encoder out of ```asm_kernel.hpp``` - it never formats a character and never
lexes one back.  Skipping the text is worth **2.9x** on the whole job, and
most of that saving is the re-lexing rather than the formatting.

Both paths have serial, multi core and HIP backends, built from one shared
device-safe kernel header so that they cannot disagree.  They are measured
separately:

| path | backend | time | lines/s | speedup |
| --- | --- | --- | --- | --- |
| text | serial | 301 ms | 2.06 M | 1.00x |
| text | threads | 83.2 ms | 7.45 M | 3.62x |
| text | hip | 95.3 ms | 6.51 M | 3.16x |
| binary | serial | 240 ms | 2.59 M | 1.00x |
| binary | threads | 64.3 ms | 9.65 M | 3.73x |
| binary | hip | 66.1 ms | 9.38 M | 3.62x |

15.41 MiB of generated source, 620008 lines, on 24 cores and a Radeon RX 9070
XT.  Parallelism breaks even at about 0.39 MiB of source; below that it is a
straight loss, and since a real cpu16 program is at most a few hundred lines,
**the serial backend is the right one for every program the hardware can
actually run.**  The GPU ties with 24 cores on the binary path and loses on
the text path.  ```cmake --build build --target benchc``` reproduces the
table; ```build/c16_bench --sweep``` reproduces the break even.

The language, its grammar, its limits, the register and call model and the
full benchmark are in [```docs/c16.md```](docs/c16.md).

## Instruction Set Architecture - 8 Bit Instruction/Register SIMD32

Dropped.  ```cpu8_simd.v``` was a sketch that never compiled, and the SIMT
design in [```docs/gpu_isa.md```](docs/gpu_isa.md) supersedes it - see
"Removed modules" below.

## Instruction Set Architecture - 32 Bit Instruction SIMT GPU

See [```docs/gpu_isa.md```](docs/gpu_isa.md).  The scalar unit exists in
```gpu16.v``` and the assembler in ```asm_gpu16```; the vector unit, the exec
mask, the LDS and the matrix unit do not yet.

```gpu16``` is a SIMT sibling of cpu16 aimed at tiled integer GEMM: 16 lanes
per wavefront with a software-managed exec mask, 16 scalar and 16 vector
registers plus 32 matrix accumulators per lane, an 8 KiB scratchpad with a
barrier, and an ```mma_i8``` matrix multiply-accumulate that does a 16x16x4
```int8``` block into ```int32``` accumulators.  The document carries the full
bit-level encoding in the same style as the cpu16 tables above, a worked
tiled GEMM kernel with its register-blocking analysis, and a benchmark plan
with predicted numbers for three tiers - analytical model, RTL simulation
through this CTest harness, and a real tapeout.

Revision 3 closes all six of the spec's open questions.  ```B```
pre-transposed is a precondition, the wavefront is 16 lanes for the first
implementation, the wide ```v_ld16_g```/```v_st16_g``` accesses were added
with a correctness test and an A/B benchmark control, 32 accumulators per lane
is confirmed, and the accumulator file's 16-lane 32-bit read-modify-write is a
stated architectural requirement.  The scalar unit is a widened
```cpu16.v```, so gpu16's scalar opcodes are realigned onto cpu16's numbering
- cpu16's five branch opcodes already matched exactly - and making
```cpu16.v``` synthesisable becomes work that comes before the GPU rather than
before a tapeout.  ```s_waitcnt``` is split into ```s_waitcnt_g``` and
```s_waitcnt_l```.

### What is built

```gpu16.v``` implements ```gpu16```: the widened ```cpu16.v``` that section
4.13 calls for - 16 x 32 bit scalar registers, 4 bit register select fields, a
16 bit word addressed PC, a 24 bit data address, sign extended 16 bit
immediates and a 32 bit instruction word with an 8 bit opcode - with section
1.1's sixteen lanes hanging off the same fetch and the same decode.  It
decodes the whole of section 4.3's scalar ALU, all of section 4.4's control
flow including the two exec-mask branches, section 4.5's exec mask
instructions, ```s_ld_g```, and ```s_waitcnt_g```, ```s_endpgm``` and
```s_nop```.

```gpu16_vector.v``` is the lane datapath: the 16 x 16 x 32 bit register file
and the whole of section 4.6's vector ALU, one cycle per instruction.  There
is no reconvergence stack and no per-lane PC anywhere in either file, because
section 1.3 puts divergence in software: a wave narrows ```exec``` with
```s_and_saveexec```, skips an empty side with ```s_cbr_execz```, and
reconverges by restoring the mask it saved in an SGPR.  Section 1.2's rule
that a disabled lane still *reads* its operands is what makes ```v_bpermute```
and ```v_readlane``` well defined while the wave is divergent.

```gpu16_gmem.v``` is global memory as wide as section 3.1 says it is: the
array underneath is still 32 bit words, so a ```.data32``` file loads into it
with one ```$readmemh```, but the port on the outside is one aligned 64 byte
block per cycle.  The memory unit in ```gpu16.v``` is what turns sixteen lane
addresses into transactions, and it implements section 3.1's rule literally -
sort the enabled lanes' addresses into distinct aligned 64-byte blocks and
spend one cycle per distinct block - so sixteen lanes reading four
consecutive bytes each cost one cycle and sixteen lanes walking a matrix
column cost sixteen.  At the register file end it moves one VGPR per cycle,
which is one cycle for a 1 or 4 byte access and four for ```v_ld16_g``` or
```v_st16_g```, exactly the argument section 4.8 makes for why a wide access
needs no extra register file port.  The wave stalls for those cycles, so
```s_waitcnt_g``` still has nothing to wait for.

The whole of section 4.8 now runs: ```v_ld_g```, ```v_ld_gs```,
```v_ld4_g```, ```v_ld16_g```, ```v_st_g```, ```v_st4_g```, ```v_st16_g```
and ```s_ld_g```.

```gpu16_lds.v``` is the other memory, and the interesting thing about it is
that it is *sixteen* memories.  Section 3.2 organises the 8 KiB scratchpad as
sixteen banks of four bytes with ```bank = (address >> 2) & 15```, so the
module is sixteen independently addressed 32 bit arrays and the address
splits as row 12:6, bank 5:2, byte 1:0 - which makes the flat word index
```{row, bank}```, i.e. just ```address >> 2```, so a plain array still
underlies it.  The same memory unit drives it, with one rule swapped: global
memory serves one aligned 64 byte block per cycle, LDS serves any set of
lanes that hits sixteen distinct banks, whatever rows they are in.  Choosing
that set is a greedy sweep - walk the unfinished lanes in order, take each
one whose bank is still free - which costs exactly as many cycles as the most
heavily hit bank has lanes, which is section 3.2's "one cycle per conflicting
way".  ```perf_lds_cycles``` (system register 12) counts them.

Two things there are deliberate.  Two lanes reading the *same* LDS address
are two ways and not a broadcast, because section 3.2 states its rule in
terms of distinct banks and says nothing about matching addresses, and a
broadcast path would make the machine faster than the document promises on an
access the document says is slow.  And an *n*-way conflict costs exactly *n*
cycles, which section 6.4 lists as an open question - "much less confident
that a real LDS implementation will actually resolve a 2-way conflict in
exactly 2 cycles rather than 4" - so that question now has an answer in RTL.

```gpu16_cu.v``` is the compute unit, and it exists because three things in
the ISA are statements about waves other than this one.  Section 3.2's LDS is
"shared by the 4 waves of a workgroup"; section 3.3's ```s_barrier``` waits
until all of them have arrived; section 7.2's Model-A issues "one instruction
per cycle per compute unit, round-robin over ready waves".  None of the three
can be implemented, or falsified, one wave at a time - a private scratchpad
passes every single-wave value test ever written, and a barrier with nobody
to wait for is a no-op.

So the compute unit owns everything shared - the global memory, the LDS, the
issue slot, the barrier and the three workgroup performance counters - and
```gpu16.v``` is now only a wave: a PC, registers, an exec mask and a memory
unit that *asks* for a port rather than containing one.  A wave whose request
is not granted does not advance that cycle, which is the whole contention
model and is why a workgroup does not simply take four times as long as a
wave.  The issue slot rotates, as Model-A says; each memory port goes to the
lowest numbered wave asking for it, which cannot starve anyone because every
request is for at most sixteen port cycles and then stops.

```s_barrier``` is not executed and then waited on - it is *not issued* until
the unit has seen every wave arrive.  That is what makes the arrival
condition stable: a wave that had already issued its barrier and run on would
stop counting as arrived and strand the others.  A wave that has ended counts
as arrived, so a workgroup whose waves do not all reach the same number of
barriers does not deadlock on the dead one.

Only ```tests/gpu_wg.s``` launches more than one wave; every other test runs
with one, in which configuration each grant is unopposed and the machine
behaves cycle for cycle as it did before the unit existed.

The matrix unit (4.7) is still absent and still reports ```unknown opcode```
rather than guessing.

The one thing added to the ISA rather than implemented from it is system
register 13, ```perf_gmem_trans```: the transaction count.  Section 4.3's
counters can see the bytes a kernel asked for but not how many port cycles it
took to move them, and those are different numbers whenever an access is not
perfectly coalesced - section 3.1's own worked example is a fill that runs at
50% transaction efficiency.  Without it the rule the whole memory system is
built on would be observable only as an unexplained difference in
```perf_cycles```, which is a poor thing to write a regression test against.

```asm_gpu16``` is the assembler, and it is the whole ISA rather than the
part that runs: all 97 documented instructions assemble, scalar and vector
alike.  It is the same tool as ```asm``` and ```asm16``` - the same command
line, the same five passes, the same per line kernel in ```asm_kernel.hpp```,
so the same serial, threaded and HIP backends - with three things the ISA
needed and the other two did not.  Its operands are typed, because section
4.2 fixes which register file each field names, so ```v_add v1, s2, v3``` is
an error and not a different instruction.  Their number is per instruction,
from none for ```s_endpgm``` to four for ```v_mad```.  And a label may stand
in for an address anywhere the ISA takes one, not only after ```la``` -
```s_bnz_i s3, loop``` for a word offset from the next instruction,
```s_imm s7, target``` for a plain word address.  ```la s10, target``` is one
```s_addpc```, because unlike cpu8 this machine can add to its own PC.

```testgpu.v``` is its testbench, modelled on ```test16.v```, and the
sixteen ```gpu_*``` CTests assemble a program with ```asm_gpu16```, run it on
a ```gpu16_cu``` compute unit and check all sixteen scalar registers of wave
0.  ```+waves``` says how many of the four wave slots to launch and defaults
to one; a multi wave program that wants to say something about wave 3 has to
get the answer to wave 0 through memory, which is a more honest test than
reaching into another wave's register file from the testbench.  A gpu16 program must
reach ```s_endpgm```: unlike cpu16, running off the end is a failure even if
the registers look right.  The five scalar programs' ```.expect``` files were
written when the programs were hand encoded hex and have not been touched
since, so a pass now says the assembler and the RTL read section 4.1 the same
way.

The four vector programs pass a second expectation file, ```+vexpect```,
holding all 256 VGPRs - sixteen lanes of ```v0```, then sixteen of ```v1```,
and so on - so what is checked is every lane and not the wave as a whole.
```gpu_vector``` makes every result a function of the lane index, because a
value that is the same in all sixteen lanes proves nothing about a sixteen
lane machine.  ```gpu_divergent``` is section 1.3's worked if/else, with the
two halves of the wave computing different answers and reconverging on the
saved mask.  ```gpu_exec``` is the one that would be missing if these had been
written by someone used to a scalar machine: every mask in it has bit 0 set
and every value written is the value lane 0 should hold, so lane 0 alone
cannot tell this machine from one with no exec mask at all, and the whole
difference is in lanes 1..15 keeping what they had.  Deleting the exec term
from the vector write, or the exec AND from ```v_cmp```, or the lane select
from ```v_writelane```, each fails at least one of them.

Four more programs cover section 4.8.  ```gpu_global``` and ```gpu_gstore```
check what the loads bring back and what the stores leave behind, including
the two halves of the exec rule - a masked store must not touch the disabled
lanes' *memory*, a masked load must not touch their *registers* - and
```gpu_gwide``` does the same for the 256 bytes an instruction of the
```v_*16_g``` family moves.  All three run against a data file whose only rule
is that the byte at address ```a``` holds ```a & 0xff```, so every expected
word is a function of its address and a load that lands one byte or one lane
out of place cannot accidentally match.

```gpu_lds``` and ```gpu_bank``` are the same pair of jobs for the
scratchpad.  ```gpu_lds``` writes and reads back seven regions - including
sixteen lanes writing sixteen *consecutive bytes*, which is four lanes to a
bank word and therefore a byte enable test, and section 3.2's own 36 byte row
stride, which is the only access in the suite where a lane's bank is not its
lane number - and finishes by re-reading the first region to show that 8 KiB
really is 2048 distinct words.  ```gpu_bank``` checks the cost rather than
the contents: it reads ```perf_lds_cycles``` either side of accesses at
strides of 4, 36, 32 and 8 bytes and asserts 1, 1, 8 and 2 port cycles, which
is section 3.2's argument for the 36 byte pad reduced to two numbers - one
cycle against eight for the same sixteen lanes reading the same sixteen rows.
Eleven mutations were run against the pair, including a three-bit bank index,
the bank taken from the wrong address bits, the row taken from the wrong
address bits, a bank array indexed ```{bank, row}```, no conflict resolution
at all, one lane per cycle whatever the pattern, and a ```v_st_l``` that
writes its whole bank word; every one fails at least one of the two, and the
timing mutations fail only ```gpu_bank```.

```gpu_coalesce``` is the one that checks something values cannot see.  A
machine that issues sixteen transactions for every access returns exactly the
same data as one that coalesces, so the test reads ```perf_gmem_trans``` either
side of five accesses of known shape and asserts 1, 16, 2, 4 and 1
transactions, and reads ```perf_cycles``` either side of two of them to show
the cost is real: seven cycles for the access that costs one transaction and
twenty-two for the one that costs sixteen, a difference of exactly one cycle
per extra transaction.  Ten mutations of the memory unit were run against
these four tests - no coalescing at all, a 32-byte block index, exec ignored
on either side, a big-endian quad, both address truncations removed, a byte
store that writes the whole word, and a ```v_ld_gs``` that zero extends - and
every one of them fails at least one test.

```gpu_wg``` is the only test that launches four waves, and it is the only
one that can say anything about the three things that need more than one.
Every wave runs the same program and is told apart only by ```s_rd_sys 0```.
Each poisons its own LDS slot, a barrier makes that complete, wave 3 is then
sent round a long delay loop before it writes the real value, and every wave
sums all four slots after a second barrier - so a private scratchpad, or a
barrier that does not wait, reads the poison and gets 0x33 instead of 0x46.
The same argument is then made through global memory, where wave 0 reads back
with ```s_ld_g``` a word only wave 3 ever wrote.

Two sections then turn all sixteen lanes on and put both ports under load
from all four waves at once, bounded by a barrier at each end: sixteen lanes
at a 64 byte stride are one bank sixteen ways over in the LDS and sixteen
distinct blocks in global memory, so the workgroup's counters must read 64
port cycles, 64 transactions and 256 bytes.  Each would read 16, 16 and 64 if
a port served every wave in the same cycle, or if the counters had stayed per
wave rather than per workgroup as section 4.3's "by this workgroup" says.

The last section measures round-robin issue, which no value can see because
every schedule runs the same instructions: with four waves ready wave 0 gets
one cycle in four, so a sixteen instruction stretch costs it about 64 cycles
against 16 for a unit that let it run to completion first, and the test keeps
whether the figure cleared 32.  Twelve mutations were run against the wave
and the compute unit - the barrier release tied high, a barrier that waits
only for wave 0, permission that is never spent so one barrier passes
forever, a wave that does not wait at a barrier at all, a memory unit that
advances without a grant, round robin replaced by fixed priority, two waves
issuing in the same cycle, either port granted to every requester at once,
each of the three counters reverted to counting one wave, and ```launch```
ignored so that every test runs four waves - and every one of them fails a
test.  Eleven fail ```gpu_wg```; the twelfth, ```launch```, falls to the
single-wave counter tests, which is the right answer for it.

```gpu16_matrix.v``` is the matrix unit, section 4.7, and the reason the rest
of the machine exists.  One ```mma_i8``` is ```D += A * B``` with A a 16x4
```int8``` fragment, B a 4x16 one and D a 16x16 ```int32``` accumulator block:
1024 MACs in a single instruction word, walked by a 64-MAC array over sixteen
cycles, one accumulator row per cycle.  That rate is not an implementation
choice but requirement A1 read backwards - the accumulator file sustains one
16-lane by 32-bit read-modify-write per cycle and no more, so sixteen rows
take sixteen cycles, and section 2.3's own note that doubling the array
without doubling that port would make ```mma_i8``` a 32-cycle instruction is
the same arithmetic.

The structural claim worth checking in RTL is section 4.7's, because the area
estimate in section 6 rests on it.  ```vB``` is read per lane: on every cycle
lane n wants ```B[k][n]```, which lives in lane n's own register, and that is
free.  ```vA``` is read *across* lanes, which sounds like the expensive case -
but the unit walks one m per cycle, so on the cycle that computes row m all
sixteen lanes want the same 32-bit word, the one in lane m.  That is a 16:1
mux of 32 bits selected by the row counter, not a 16x16 crossbar, and the
difference is about two orders of magnitude of wiring.  It builds exactly as
specified: ```gpu16_matrix.v``` takes A as a single ```[31:0] a_frag``` port
and B as ```[511:0]```, so the property is visible in the module's interface
rather than buried in an ```always``` block, and a crossbar version could not
be connected to it without widening the port.  The multiplexing itself is one
line in ```gpu16_vector.v```, ```mat_a = vregs[{mat_areg, mat_row}]```, which
is the only place in the design where a register is read from a lane other
than its own outside ```v_readlane``` and ```v_bpermute```.

The array is one per compute unit and shared by the four waves, arbitrated
round-robin; the accumulator file is per wave and per lane, as section 2.3
says.  Section 7.3 is what settles that: "four waves give 324 issue slots
against 1024 matrix cycles per workgroup iteration" is 4 x 256, which only
reads as one array the waves queue for.  Round-robin rather than the fixed
priority the memory ports use, because a wave can re-arm an ```mma``` on the
cycle its last one retires and under fixed priority would starve its
neighbours indefinitely.  ```acc_zero``` is a sixteen-cycle walk too, not a
single-cycle clear of 256 words, for the same port reason - but it does not
request the array, so it does not show up in ```perf_mma_busy```.

Six tests check the value and two the timing.  ```gpu_mma``` seeds a block
through ```acc_wr``` with ```C0[m][n] = 0x1000 + 16m + n``` - a function of
both indices, so a tile that is transposed or one row out of place cannot
match even before the products are added - accumulates two K steps onto it
with no manual wait anywhere, and reads all sixteen rows back with
```acc_rd```; it works in block A1 with A0 filled with something else, so the
top bit of the five-bit accumulator number is under test as well.
```gpu_mma_z``` poisons all thirty-two accumulators and then takes both of
section 4.7's routes to a fresh tile, ```acc_zero``` plus ```mma_i8``` in one
block and ```mma_i8_z``` in the other, and subtracts the two blocks *in the
machine* into ```s8``` - so that half of it does not depend on the
expectation file being right at all.  ```gpu_mma_exec``` is section 4.7's
sharp edge: with ```exec = 0x0f0f``` the disabled lanes keep their old
accumulators but still supply their A row, so a unit that masked the A read
would corrupt rows that the mask was supposed to protect.

The other two are a matched pair, and they are the reason the mutation table
below means anything.  A matrix unit that reads B across lanes and A per lane
computes a perfectly respectable product - the transpose of the right one -
and no amount of checking a symmetric example will notice.  ```gpu_mma_sym```
is that symmetric example, ```D = As * As^T``` built so the answer equals its
own transpose, and it is in the suite to be *passed* by that bug;
```gpu_mma_map``` runs the same program on an asymmetric product where all 240
off-diagonal entries differ from their transpose, and catches it.

Every ```.expect``` and ```.vexpect``` here is computed by
```tests/gen_mma_expect.py```, which is section 4.7's loop transcribed into
Python, and none was ever read back from the simulator - an expectation is
worth exactly what its provenance is worth.  ```gpu_mma_expect``` re-runs the
generator inside CTest and diffs its output against the checked-in files, so
a later session cannot quietly repair a failing test by pasting in what the
hardware printed.

```gpu_mma_perf``` measures what no computed value can see, and its three
numbers were predicted from the document before the simulator was run: an
```acc_zero``` stretch of 19 cycles, eight back-to-back ```mma_i8``` of 131,
and ```perf_mma_busy``` on sysreg 10 advancing by exactly 128.  The middle
one is the headline: **an ```mma_i8``` costs 16 cycles, matching section
4.7**, and back-to-back is 16 and not 17 only because the next matrix
instruction is allowed to issue on the walk's last cycle.  Model-A's "a wave
issuing a second ```mma``` stalls until the unit frees" is ambiguous on that
cycle, and section 7.3's 1024 matrix cycles per workgroup iteration is the
tie-breaker: 16 x 16 x 4 is 1024, where the stricter reading would give 1088.
```acc_rd``` and ```acc_wr``` are *not* allowed to slip in that way, since
they touch the accumulator file in their issue cycle.  ```gpu_mma_wg``` then
runs four waves of eight ```mma``` each and requires ```perf_mma_busy``` to
read 512 - four times one wave's 128, with no arbitration overhead and no
overlap - which is the shared-array claim stated as a number.

So section 7's matrix figures rest on arithmetic that now holds: sixteen
cycles per ```mma_i8```, additive across the four waves of a workgroup, with
round-robin arbitration costing nothing because the array is saturated
whenever anyone is waiting for it.  What is *not* yet measured is the other
half of the utilisation fraction - 76.1%, 85.3% and 90.7% come from those
1024 cycles divided by 1056, 1024 + 32 for the barrier, and that denominator
assumes the 324 issue slots of section 5.3's GEMM kernel hide entirely under
the matrix work.  Nothing in this harness has run that kernel, so those three
percentages remain predictions with a confirmed numerator.

Eleven mutations were run against the matrix unit, and each is listed with the
test that catches it: A and B swapped so the product transposes
(```gpu_mma_map```, while ```gpu_mma_sym``` passes - exactly the pair they
were built for), the A fragment read from lane 0 instead of through the row
mux (everything), the accumulator row index off by one (everything), the
block select in ```mma_i8``` ignored (```gpu_mma```, ```gpu_mma_z```), the
block bit of ```acc_rd```/```acc_wr``` ignored (```gpu_mma```), ```exec```
ignored on the accumulator write (```gpu_mma_exec```), ```mma_i8_z```
accumulating like ```mma_i8``` (```gpu_mma_z```), ```acc_zero``` filling ones
instead of zeroes (```gpu_mma_z```), the ```int8``` operands zero extended
instead of sign extended (everything), the last-cycle issue removed so
back-to-back ```mma``` costs 17 cycles (```gpu_mma_perf``` alone, since no
value changes), and the array un-shared so all four waves are granted every
cycle (```gpu_mma_wg``` alone, for the same reason).

Simulation now reaches every instruction in the ISA, but ```gpu_encoding```
still covers what no simulation can: it assembles all 97 instructions and
compares the words against ```tests/gpu_encoding.expect32```, which needs no
hardware at all.  That expectation was not produced by running the assembler
- it came from a script that read section 4.2's field table and sections 4.3
to 4.10's opcode tables out of the markdown - and it ends with section 4.11's
twelve worked encodings copied out of the document's prose.  ```gpu_reject```
is the other half: the rules the document states and no hardware enforces, so
that source which is not gpu16 fails to assemble instead of assembling into
something.

Revision 4 adds section 8, which answers a follow-up question: should the
instruction word be enlarged to carry 5-bit register fields and a 32-entry
vector register file?  The answer is no.  Checking the premise against the
benchmark numbers shrank it - the kernel that argument rested on is already at
94.5% of the global memory port, so the whole prize was 5.5% on one benchmark
and nothing at all on GEMM, while widening the word would have cost more area
in program memory than the extra registers cost by themselves and pushed the
small configuration off the cheapest tapeout route.  The recommendation is to
take the 5-bit fields for free instead, by absorbing an argument field that
only two instructions use, implement 16 registers anyway, and solve the actual
kernel problem with a bit that is already dead in ```v_ld16_g```.

## Instruction Set Architecture - 16/16/16/16

[```docs/cpu_16_16_16_16.md```](docs/cpu_16_16_16_16.md) is the fourth core in
the family, and its name is the family's own convention spelled out: a 16 bit
instruction word, a 16 bit datapath, 16 registers and a 16 bit program
counter, so 64 KiB of code and 64 KiB of data.  It is ```cpu_16_16_16_16.v```
and it does not touch ```cpu8.v```, ```cpu16.v``` or ```gpu16*.v```.

The interesting part of the design is that 16 registers cost four bits each,
so a two register instruction has already spent half of the word before it
has said what to do.  The answer is the same one ```cpu16.v``` reaches for and
pushed further: instructions are two address, ```op rd, rs``` meaning
```rd = rd op rs```, and the encoding is split by class in ```Inst[15:12]```.
Class ```00xx``` gives the register format a full eight bit opcode, which is
where the 35 register operations live; classes 4 to 7 and a to b give six
immediate forms an eight bit immediate and one register; classes 8 and 9 give
```ld```/```st``` a register pair and a four bit halfword offset; class c
gives a branch a four bit condition and a signed eight bit word displacement;
classes d and e give ```jmp``` and ```call``` a signed twelve bit one.  The
immediates that had to be chosen carefully are ```movi```/```movih```, which
build any 16 bit constant in two instructions, and ```andi```/```ori```, which
zero extend where ```addi```/```cmpi``` sign extend - so a mask keeps its high
bits clear and an addend can be negative.

```asm_16_16_16_16``` is another ```asm_kernel.hpp``` struct and a three line
```main```, so it inherits the serial, threads and HIP backends for free;
```asm_bench --isa 1616``` reports all three producing identical output.  Two
diagnostics that were previously hard coded in ```asm_pipeline.hpp``` are now
per ISA strings, because "0-7" is not the register range here; the ```gpu16```
and ```cpu8``` wording is unchanged to the byte, which ```gpu_reject``` checks.

Seventeen tests cover it.  Four are assembler level - an encoding test whose
expected words come from a second, independent Python encoder written from the
document rather than from the assembler, a 36 case rejection test, a branch
range test that walks both edges, and the two backend agreement tests.  Eleven
are simulations written in assembler source with expectations computed by hand
from the specification, never captured from the RTL; the ```branch``` one
exercises all fifteen conditions against three different flag states, and
```mem``` and ```sum``` check data memory as well as registers.

Fifty mutations were run against the core and the assembler with
[```tests/mutate_cpu_16_16_16_16.py```](tests/mutate_cpu_16_16_16_16.py), and
the first run caught 44 of them.  The four that escaped were all the same kind
of gap - a rule the tests asserted only where it did not matter.  ```mov```
could be made to write flags because no test read a flag across a ```mov```;
```cmp``` could be made to write its result back because every ```cmp``` in
the tests was followed by a branch and never by a use of the destination; the
read side forwarding path for ```ld```/```st``` could be deleted because no
test ever stored the value it had just loaded; and ```andi``` could be made to
sign extend because no test used a mask with bit 7 set.  Three lines added to
```flags.s```, two blocks added to ```imm.s``` and a load-then-store pair in
```mem.s``` closed all four, and a fifth mutation - the same sign extension
bug in ```ori``` - was added at the same time.  The rerun catches all fifty.

## Putting it on an FPGA

[```docs/fpga_bringup.md```](docs/fpga_bringup.md) is a plan, not a build:
there is no Vivado on the machine it was written on, so everything it says
about synthesis comes from reading the RTL rather than from a report.  It is
simulation-first on purpose - the 68 tests already settle functional
correctness, so a board can only add ```Fmax```, fit and the things outside
the RTL - and it carries two findings worth reading before anyone buys a
board.  The program memory is instantiated with ```write_enable``` tied low
and has no ```initial``` block, so a synthesis tool has nothing to keep it
alive; and global memory is 4 KiB on chip with no external memory interface,
so not one of the six benchmark kernels in
[```docs/gpu_isa.md```](docs/gpu_isa.md) section 7 can run, on a board or in
simulation.

## Widening it to 32 bits, and Linux

[```docs/cpu32_linux.md```](docs/cpu32_linux.md) asks what it would take to
boot a Linux kernel on this family's own ISA, and answers it honestly rather
than optimistically.  Three things in it are worth knowing without reading
the whole document.  The width is the part that is already done - ```gpu16```'s
scalar unit *is* a 32 bit ```cpu16.v``` by construction, so the plan promotes
it rather than widening ```cpu16.v``` a second time.  What is actually
missing is a scalar load/store unit (```gpu16``` has ```s_ld_g``` and no
store at all), a trap architecture, a timer, a console and a boot path -
eleven hardware prerequisites of which this repository has none.  And the CPU
is the small part: all of that RTL is months, while the compiler backend and
the kernel port after it are years.  It is a plan and not a build; nothing in
it has been implemented or measured, and its section 9 lists every claim that
is a prediction.

## Removed modules

Two modules were deleted rather than repaired, because neither could be given
a test in this harness and both had been superseded:

* ```cpu8_simd.v```, a 32 lane SIMD sketch.  It never compiled - an invalid
  ```signal[]``` port syntax where it needed a ```generate``` loop, an
  undefined ```SIMD_WIDTH```, a lane variable used outside the loops that
  declared it, and one single ported data memory shared by all 32 lanes.
  Repairing it meant designing a per lane memory system and a divergence
  model from scratch, which is exactly what
  [```docs/gpu_isa.md```](docs/gpu_isa.md) now specifies properly, with an
  exec mask, a banked scratchpad and a stated memory transaction rule.  It
  also declared a module called ```cpu_inst8_data8```, the same name as the
  one in ```cpu8.v```, so the two could never be used together anyway.
* ```memory_ramb18e1.v```, a wrapper around the Xilinx ```RAMB18E1``` block
  RAM primitive.  It redeclared every one of its ports, its body was entirely
  commented out, and it instantiates a vendor primitive that is not in this
  repository, so no testbench here can ever compile it.  ```memory.v``` is the
  portable version.  Its read port is asynchronous, which is what keeps the
  CPUs' timing what it has always been, so synthesis infers distributed RAM
  from it rather than a block RAM.

The ```verilog_lint``` test exists so that nothing rots this way again: it
compiles every ```*.v``` on its own with ```-Wall``` and fails on any message.

## Known gaps

* ```variables_to_registers``` is not implemented.
* ```gpu16``` implements the whole ISA including section 4.7's matrix unit,
  so nothing in it is held down by ```gpu_encoding``` alone any more.  What
  has still never been run is section 7.4's GEMM kernels themselves: the
  matrix unit's sixteen cycles and their sum across four waves are measured,
  but the utilisation percentages in section 7.3 divide those by a cycle
  count for a kernel no test here executes.  Global accesses complete before
  the next instruction issues, so ```s_waitcnt_g``` is architecturally
  required but does nothing; there is deliberately no forwarding from a load
  into the next instruction, so a program that omits the wait does not
  accidentally work.
