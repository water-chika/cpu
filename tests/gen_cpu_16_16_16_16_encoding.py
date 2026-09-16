#!/usr/bin/env python3
"""Encode tests/cpu_16_16_16_16_encoding.s from the document, not from the
assembler.

The point of an encoding test is that two people read docs/cpu_16_16_16_16.md
and got the same bits.  If the expectation were captured from asm_16_16_16_16
it would only say that the assembler agrees with itself, so this is a second,
independent implementation of sections 3, 8 and 9: the field layout below is
transcribed from the document's tables and nothing here has ever looked at
asm_kernel.hpp.

usage:
    gen_cpu_16_16_16_16_encoding.py < tests/cpu_16_16_16_16_encoding.s \\
        > tests/cpu_16_16_16_16_encoding.expect16
"""

import sys

# Section 3.1: the R format opcode byte, Inst[15:8].
R_OPS = {
    "and": 0x00, "or": 0x01, "not": 0x02, "xor": 0x03,
    "add": 0x04, "adc": 0x05, "sub": 0x06, "sbb": 0x07,
    "neg": 0x08, "mul": 0x09, "div": 0x0A, "mov": 0x0B,
    "cmp": 0x0C, "tst": 0x0D, "shl": 0x0E, "shr": 0x0F,
    "sar": 0x10, "rol": 0x11, "ror": 0x12,
    "shli": 0x13, "shri": 0x14, "sari": 0x15,
    "roli": 0x16, "rori": 0x17,
    "ldb": 0x18, "stb": 0x19, "sxb": 0x1A,
    "min": 0x1B, "max": 0x1C,
    "jmpr": 0x1D, "callr": 0x1E, "rd_sys": 0x1F,
    "halt": 0x20, "nop": 0x21, "ret": 0x22,
}

# R instructions that name only one register, and put it in the rs field.
R_ONE_REG = {"jmpr", "callr"}
# R instructions that name nothing at all.
R_NO_REG = {"halt", "nop", "ret"}

# Section 3.2: the immediate classes, Inst[15:12].
I_CLASS = {"movi": 0x4, "movih": 0x5, "addi": 0x6,
           "cmpi": 0x7, "andi": 0xA, "ori": 0xB}

# Section 3.3.
M_CLASS = {"ld": 0x8, "st": 0x9}

# Section 3.4: the condition nibble, Inst[11:8].
B_COND = {"beq": 0x0, "bne": 0x1, "blo": 0x2, "bhs": 0x3,
          "bmi": 0x4, "bpl": 0x5, "bvs": 0x6, "bvc": 0x7,
          "bhi": 0x8, "bls": 0x9, "bge": 0xA, "blt": 0xB,
          "bgt": 0xC, "ble": 0xD, "br": 0xE}

# Section 3.5.
J_CLASS = {"jmp": 0xD, "call": 0xE}


def reg(tok):
    assert tok[0] == "r", tok
    value = int(tok[1:], 10)
    assert 0 <= value <= 15, tok
    return value


def number(tok):
    return int(tok, 0)


def words_of(mnemonic):
    """Section 8: 'la' is two words, everything else is one."""
    return 2 if mnemonic == "la" else 1


def parse(text):
    """Return [(address, mnemonic, operands)] and {label: word address}."""
    statements = []
    labels = {}
    address = 0
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        while line.endswith(":") or ":" in line:
            head, sep, rest = line.partition(":")
            if not sep:
                break
            head = head.strip()
            assert head and " " not in head, raw
            assert head not in labels, "label defined twice: " + head
            labels[head] = address
            line = rest.strip()
        if not line:
            continue
        parts = line.replace(",", " ").split()
        statements.append((address, parts[0], parts[1:]))
        address += words_of(parts[0])
    return statements, labels


def encode(address, mnemonic, args, labels):
    if mnemonic in R_OPS:
        op = R_OPS[mnemonic]
        if mnemonic in R_NO_REG:
            rd, rs = 0, 0
        elif mnemonic in R_ONE_REG:
            rd, rs = 0, reg(args[0])
        elif mnemonic == "rd_sys":
            rd, rs = reg(args[0]), number(args[1])
        elif 0x13 <= op <= 0x17:
            rd, rs = reg(args[0]), number(args[1])
        else:
            rd, rs = reg(args[0]), reg(args[1])
        return [(op << 8) | (rs << 4) | rd]

    if mnemonic in I_CLASS:
        rd = reg(args[0])
        imm = number(args[1]) & 0xFF
        return [(I_CLASS[mnemonic] << 12) | (imm << 4) | rd]

    if mnemonic in M_CLASS:
        rd, rs, off = reg(args[0]), reg(args[1]), number(args[2])
        assert 0 <= off <= 15
        return [(M_CLASS[mnemonic] << 12) | (rd << 8) | (rs << 4) | off]

    if mnemonic in B_COND:
        # Section 6: the displacement is counted in instruction words from
        # PC_next, which is one word past this instruction.
        disp = labels[args[0]] - (address + 1)
        assert -128 <= disp <= 127, (mnemonic, args, disp)
        return [0xC000 | (B_COND[mnemonic] << 8) | (disp & 0xFF)]

    if mnemonic in J_CLASS:
        disp = labels[args[0]] - (address + 1)
        assert -2048 <= disp <= 2047, (mnemonic, args, disp)
        return [(J_CLASS[mnemonic] << 12) | (disp & 0xFFF)]

    if mnemonic == "la":
        # Section 8: movi of the low byte then movih of the high byte of the
        # label's *byte* address, which is twice its word address.
        rd = reg(args[0])
        byte_address = labels[args[1]] * 2
        return [(0x4 << 12) | ((byte_address & 0xFF) << 4) | rd,
                (0x5 << 12) | (((byte_address >> 8) & 0xFF) << 4) | rd]

    raise AssertionError("unknown mnemonic: " + mnemonic)


def main():
    text = sys.stdin.read()
    statements, labels = parse(text)
    out = []
    for address, mnemonic, args in statements:
        words = encode(address, mnemonic, args, labels)
        assert len(words) == words_of(mnemonic)
        for word in words:
            out.append("%04x" % (word & 0xFFFF))
    sys.stdout.write("\n".join(out) + "\n")


main()
