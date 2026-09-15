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

Each test assembles a program from source, runs it on the verilog CPU under
```iverilog```, and compares the final register values against a checked in
```tests/*.expect``` file (```xx``` means "do not care").  A test fails if the
assembler rejects the program, if the CPU decodes an unknown opcode because
the program ran off its end, or if any register holds an unexpected value.
Nothing is generated ahead of time, so a fresh clone can run the tests
straight away.

| Test | Program | Checks |
|------|---------|--------|
| verilog_lint | every ```*.v``` | each verilog source compiles on its own under ```iverilog -Wall``` without a single message |
| cpu8_sum | tests/cpu8_sum.s | 8 bit CPU sums 1..8 out of data memory into r2 |
| cpu8_sum_list | cpu8_asm/sum.s | 8 bit CPU sums the whole of data.list (1..16) into r2 |
| cpu8_label | tests/cpu8_label.s | 8 bit assembler resolves a label at address 75 and the CPU branches there |
| cpu16_sum | tests/cpu16_sum.s | 16 bit CPU sums 1..8 out of data memory into r2 |
| cpu16_count | cpu16_asm/test.s | 16 bit CPU counts to 4 and branches |
| cpu16_label | tests/cpu16_label.s | 16 bit assembler resolves a label at address 75 and the CPU branches there |
| cpu16_adc | tests/cpu16_adc.s | 16 bit CPU carries between bytes through adc and sbb |
| cpu16_ldp | tests/cpu16_ldp.s | 16 bit CPU rewrites one of its own instructions with st_p and reads it back with ld_p |

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

## Instruction Set Architecture - 8 Bit Instruction/Register SIMD32

Dropped.  ```cpu8_simd.v``` was a sketch that never compiled, and the SIMT
design in [```docs/gpu_isa.md```](docs/gpu_isa.md) supersedes it - see
"Removed modules" below.

## Instruction Set Architecture - 32 Bit Instruction SIMT GPU

Specification only, no verilog and no assembler yet.  See
[```docs/gpu_isa.md```](docs/gpu_isa.md).

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
  portable version and synthesis infers a block RAM from it.

The ```verilog_lint``` test exists so that nothing rots this way again: it
compiles every ```*.v``` on its own with ```-Wall``` and fails on any message.

## Known gaps

* ```cpu8.v``` does not implement ```ld_p```/```st_p```; it reports
  ```unknown opcode``` for them.  Only ```cpu16.v``` has the second program
  memory port they need.
* ```variables_to_registers``` is not implemented.
