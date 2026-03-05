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

| Op  |
|-----|
| add |
| sub |
| neg |
| mul |
| div |
| and |
| or  |
| not |
| xor |

#### Branch

Branch condition compare argument with 0 (zero).

| Op  |
|-----|
| b   |
| bnz |
| bz  |
| blz |
| bgz |

#### Data transfer

| Op  |
|-----|
| ld  |
| st  |
| ld_p|
| st_p|
