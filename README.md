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

Instruction memory and data memory is separated but there are instructions to transfer data between them.
