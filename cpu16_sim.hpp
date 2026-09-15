// An instruction level simulator for cpu16.
//
// This exists to answer a question the .expect files cannot: when a test
// fails, which of the compiler, the assembler and the verilog is wrong?
//
// A checked in .expect file only says that the whole stack agrees with
// whoever wrote the file.  If it disagrees, every component is equally
// suspect, and if the author's arithmetic was wrong the test is wrong in a
// way that no amount of running it will reveal.
//
// So this is a second, independent implementation of the same instruction
// set, written from cpu16.v's specification rather than from its structure.
// It shares no code with the RTL, with the assembler or with the compiler.
// That makes three way differential testing possible:
//
//   interpreter  vs  this simulator   disagreeing means the COMPILER is wrong
//   this         vs  cpu16.v          disagreeing means the RTL or this is wrong
//   text path    vs  binary path      disagreeing means the ENCODER is wrong
//
// Any single fault shows up in exactly one of those three comparisons, which
// is what localises it.
//
// The model here is purely architectural: one instruction at a time, in
// order.  cpu16's only timing quirk is the one cycle stall after a taken
// branch, during which the fetched word is forced to zero - opcode 0 with
// every operand zero, which is "r0 = r0 & r0" and therefore architecturally
// invisible.  A load's writeback lands before the next instruction reads its
// operands, so that is invisible too.  Nothing else in cpu16.v is pipelined,
// so sequential execution is exact rather than approximate.

#ifndef CPU16_SIM_HPP
#define CPU16_SIM_HPP

#include <cstdint>
#include <string>
#include <vector>

struct cpu16_sim_result {
    bool ok = false;
    bool halted = false;        // reached a branch to itself
    std::string error;
    uint8_t reg[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    uint8_t carry = 0;
    uint64_t cycles = 0;
    std::vector<uint8_t> data;
};

// Run a program.  "program" is the instruction memory as 16 bit words,
// "data" is the 256 byte data memory's initial contents (short is fine, the
// rest is zero).  A program halts by branching to its own address, which is
// how every program in this repository ends; running out of cycles without
// halting is reported rather than silently accepted.
inline cpu16_sim_result cpu16_simulate(const std::vector<uint16_t>& program,
                                       const std::vector<uint8_t>& data_init,
                                       uint64_t max_cycles = 1000000) {
    cpu16_sim_result r;
    uint16_t prog[256] = {};
    for (size_t i = 0; i < program.size() && i < 256; i++) {
        prog[i] = program[i];
    }
    r.data.assign(256, 0);
    for (size_t i = 0; i < data_init.size() && i < 256; i++) {
        r.data[i] = data_init[i];
    }

    uint8_t* reg = r.reg;
    uint8_t pc = 0;
    uint8_t carry = 0;

    auto rot_left = [](uint8_t v, unsigned s) -> uint8_t {
        s &= 7;
        return s == 0 ? v : static_cast<uint8_t>((v << s) | (v >> (8 - s)));
    };

    for (r.cycles = 0; r.cycles < max_cycles; r.cycles++) {
        uint8_t here = pc;
        uint16_t inst = prog[here];
        uint8_t opcode = static_cast<uint8_t>((inst >> 9) & 0x7f);
        unsigned src0 = (inst >> 6) & 7;
        unsigned src1 = (inst >> 3) & 7;
        unsigned dst = inst & 7;
        // The immediate instructions reinterpret the two source fields, and
        // cpu16 builds the immediate in eight bits, so it truncates.
        uint8_t imm = static_cast<uint8_t>(src0 << src1);
        unsigned shift = src1;
        uint8_t next = static_cast<uint8_t>(here + 1);
        unsigned alu = 0;

        switch (opcode) {
        case 0:  reg[dst] = static_cast<uint8_t>(reg[src0] & reg[src1]); break;
        case 1:  reg[dst] = static_cast<uint8_t>(reg[src0] | reg[src1]); break;
        case 2:  reg[dst] = static_cast<uint8_t>(~reg[src0]); break;
        case 3:  reg[dst] = static_cast<uint8_t>(reg[src0] ^ reg[src1]); break;
        case 4:
            alu = static_cast<unsigned>(reg[src0]) + reg[src1];
            reg[dst] = static_cast<uint8_t>(alu);
            carry = static_cast<uint8_t>((alu >> 8) & 1);
            break;
        case 5:
            alu = static_cast<unsigned>(reg[src0]) + reg[src1] + carry;
            reg[dst] = static_cast<uint8_t>(alu);
            carry = static_cast<uint8_t>((alu >> 8) & 1);
            break;
        case 6:
            alu = (static_cast<unsigned>(reg[src0]) - reg[src1]) & 0x1ff;
            reg[dst] = static_cast<uint8_t>(alu);
            carry = static_cast<uint8_t>((alu >> 8) & 1);
            break;
        case 7:
            alu = (static_cast<unsigned>(reg[src0]) - reg[src1] - carry) & 0x1ff;
            reg[dst] = static_cast<uint8_t>(alu);
            carry = static_cast<uint8_t>((alu >> 8) & 1);
            break;
        case 8:  reg[dst] = static_cast<uint8_t>(-static_cast<int>(reg[src0])); break;
        case 9:  reg[dst] = static_cast<uint8_t>(reg[src0] * reg[src1]); break;
        case 10:
            if (reg[src1] == 0) {
                r.error = "divide by zero, which the hardware leaves undefined";
                return r;
            }
            reg[dst] = static_cast<uint8_t>(reg[src0] / reg[src1]);
            break;
        case 11: reg[dst] = reg[src0]; break;
        case 12: reg[dst] = imm; break;
        case 13: reg[dst] = static_cast<uint8_t>(reg[dst] | imm); break;
        case 14: reg[dst] = static_cast<uint8_t>(reg[src0] << shift); break;
        case 15: reg[dst] = static_cast<uint8_t>(reg[src0] >> shift); break;
        case 16: reg[dst] = rot_left(reg[src0], shift); break;
        case 17: reg[dst] = rot_left(reg[src0], 8 - (shift & 7)); break;
        case 18:
            reg[dst] = static_cast<uint8_t>(
                static_cast<int8_t>(reg[src0]) >> (shift > 7 ? 7 : shift));
            break;
        // IP already points past this instruction and one further, because
        // the fetch runs a word ahead of execution.
        case 19: reg[dst] = static_cast<uint8_t>(here + 2 + imm); break;

        case 32: if (reg[src0] != 0) { next = reg[src1]; } break;
        case 33: if (reg[src0] == 0) { next = reg[src1]; } break;
        case 34: next = reg[src1]; break;
        case 35: if (static_cast<int8_t>(reg[src0]) < 0) { next = reg[src1]; } break;
        case 36: if (static_cast<int8_t>(reg[src0]) > 0) { next = reg[src1]; } break;

        case 64: reg[dst] = r.data[reg[src1]]; break;
        case 65: r.data[reg[src1]] = reg[src0]; break;
        case 66: r.data[reg[src1]] = 0; break;
        case 67: {
            uint8_t was = r.data[reg[src1]];
            r.data[reg[src1]] = reg[dst];
            reg[dst] = was;
            break;
        }
        case 68: {
            uint16_t word = prog[reg[src1]];
            reg[dst] = static_cast<uint8_t>((src0 & 1) ? (word >> 8) : (word & 0xff));
            break;
        }
        case 69: {
            uint16_t& word = prog[reg[src1]];
            if (dst & 1) {
                word = static_cast<uint16_t>((word & 0x00ff) | (reg[src0] << 8));
            }
            else {
                word = static_cast<uint16_t>((word & 0xff00) | reg[src0]);
            }
            break;
        }
        default:
            r.error = "unknown opcode " + std::to_string(opcode) + " at address " +
                      std::to_string(here);
            return r;
        }

        // Every program in this repository ends by branching to its own
        // address, so that is the halt condition.
        if (next == here && opcode >= 32 && opcode < 64) {
            r.ok = true;
            r.halted = true;
            r.carry = carry;
            return r;
        }
        pc = next;
    }

    r.error = "the program did not halt within " + std::to_string(max_cycles) + " cycles";
    r.carry = carry;
    return r;
}

#endif  // CPU16_SIM_HPP
