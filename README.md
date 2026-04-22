# Water's CPU

The repo contains an ISA definition and a verilog implementation. 

## Verilog implementation

It is simulated and tested  with ```iverilog``` simulator.

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

#### Branch

Branch condition compare argument with 0 (zero).

Instruction field arg encodes register containing branch address.

| Op  | Opcode | Description |
|-----|--------|-------------|
| bnz |   16   | branch if not zero |
| bz  |   17   | branch if zero     |
| b   |   18   | branch always      |
| blz |   19   | branch if less than zero |
| bgz |   20   | branch if greater than zero |

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

Instruction is 16 bit width.

```
|f e d c b a 9 8 7 6 5 4 3 2 1 0|
| Opcode      | Src0| Src1| Dst |

Src0 op Src1 -> Dst

|f e d c b a 9 8 7 6 5 4 3 2 1 0|
| Opcode      | Op0 | Src1| Dst |

op Src -> Dst

|f e d c b a 9 8 7 6 5 4 3 2 1 0|
| Opcode      | Op0 | Op1 | Dst |

op result-> Dst

|f e d c b a 9 8 7 6 5 4 3 2 1 0|
| Opcode      | Op0 | Src1| Op2 |

op Src

|f e d c b a 9 8 7 6 5 4 3 2 1 0|
| Opcode      | Src0| Src1| Op2 |

op(Src0,Src1)
```

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
