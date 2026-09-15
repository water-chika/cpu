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

The matrix unit (4.7), the per lane memory accesses (the rest of 4.8) and LDS
(4.9) are still absent, and their opcodes still report ```unknown opcode```
rather than guessing.

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

```testgpu.v``` is its testbench, modelled on ```test16.v```, and the nine
```gpu_*``` CTests assemble a program with ```asm_gpu16```, run it on
```gpu16.v``` and check all sixteen scalar registers.  A gpu16 program must
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

Simulation can only reach the part of the ISA that ```gpu16.v``` implements,
so ```gpu_encoding``` covers the rest: it assembles all 97 instructions and
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

* ```cpu8.v``` does not implement ```ld_p```/```st_p```; it reports
  ```unknown opcode``` for them.  Only ```cpu16.v``` has the second program
  memory port they need.
* ```variables_to_registers``` is not implemented.
* ```gpu16``` has no matrix unit, no LDS and no per lane memory access, and
  therefore none of section 7.4's kernels yet - a kernel that computes needs
  a way to get its data in.  ```asm_gpu16``` assembles the instructions they
  would need, but nothing can execute them, so those are held down by
  ```gpu_encoding``` rather than by simulation.  Its global loads complete in
  one cycle, so
  ```s_waitcnt_g``` is architecturally required but does nothing; there is
  deliberately no forwarding from a load into the next instruction, so a
  program that omits the wait does not accidentally work.
