# Water's CPU

The repo contains an ISA definition and a verilog implementation. 

## Verilog implementation

It is simulated and tested  with ```iverilog``` simulator.

## Instruction Set Architecture

Instruction is 8 bit width.

```
|7 6 5 4 3 2 1 0 |
| Opcode  | Arg  |
```

There are 8 registers that is 8 bit width.

Register 0 is special register as second argument if there are 2 arguments.
Register 1 is special register as third argument if there are 3 arguments.
...

There are instructions to read/write IP (instruction pointer) register.

Instruction memory and data memory is separated but there are instructions to load/store data.

### Instructions

Opcode is 5 bit width. Arg is 3 bit width.

With 5 bit opcode, there are 32 instructions ( 2^5 == 32 ).

#### Data process

Signed integer instructions uses 2's complement representation.

Instruction field arg encodes register written or immediate.

| Op  | Opcode | Description |
|-----|--------|-------------|
| and |   0    | bitwise and |
| or  |   1    | bitwise or  |
| not |   2    | bitwise not |
| xor |   3    | bitwise xor |
| add |   4    | addition    |
| sub |   5    | substract   |
| neg |   6    | negate      |
| mul |   7    | multiply    |
| div |   8    | divide      |
| mov |   9    | move reg to reg |
| cnt |   10   | count of 1 |
| imm |   11   | move imm to reg |
| shl |   12   | shift left imm times|
| shr |   13   | shift right imm times|

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
| swap|   26   | swap register and data memory |
| ld_p|   27   | load from program memory |
| st_p|   28   | store to program memory  |
