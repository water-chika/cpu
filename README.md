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
| cpu8_sum | tests/cpu8_sum.s | 8 bit CPU sums 1..8 out of data memory into r2 |
| cpu16_sum | tests/cpu16_sum.s | 16 bit CPU sums 1..8 out of data memory into r2 |
| cpu16_count | cpu16_asm/test.s | 16 bit CPU counts to 4 and branches |

To watch a program execute, run the simulation by hand and add ```+trace```:

```
./build/asm16 --hex --sep_with_line < tests/cpu16_sum.s > /tmp/program.list
iverilog -I . -o /tmp/sim16 test16.v
vvp /tmp/sim16 +program=/tmp/program.list +data=tests/sum.data \
    +expect=tests/cpu16_sum.expect +cycles=300 +trace
```

```+program_words=<n>``` and ```+data_words=<n>``` are optional and only stop
```$readmemh``` warning that the file is shorter than the whole memory.

Since the assembler has no label support yet, every program has to end by
branching to its own address to halt, and that address has to be built by
hand out of an immediate and a shift.

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

Not implemented.

This library or executable will translate labels to memory address of instruction.

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
| ld ld_p      | unused | register holding the address | dst |
| st st_p cl swap | src0 | register holding the address | dst |

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
| adc |   5    | 0000101| addition    |
| sub |   6    | 0000110| subtract    |
| sbb |   7    | 0000111| subtract    |
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
| ld_p|   68   | load from program memory |
| st_p|   69   | store to program memory  |

#### Not implemented in cpu16.v yet

```adc``` and ```sbb``` need a carry flag, which the ISA does not define a
place for yet, and ```ld_p```/```st_p``` need a second port on the program
memory.  The assembler will happily encode all four, but the CPU reports
```unknown opcode``` when it decodes one, which fails the tests.

## Instruction Set Architecture - 8 Bit Instruction/Register SIMD32

Not implemented.  ```cpu8_simd.v``` is a sketch and does not compile:
its ```memory``` instantiation uses an invalid ```signal[]``` port syntax
where it needs a ```generate``` loop over the lanes.

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

## Known gaps

* The assembler has no label support, so branch targets are built by hand out
  of an immediate and a shift.
* ```memory_ramb18e1.v``` does not compile: it redeclares every port.
* ```cpu8_asm/sum.s``` sums 32 words but ```data.list``` only holds 14, so it
  reads uninitialised memory.  ```tests/cpu8_sum.s``` is the fixed version.
