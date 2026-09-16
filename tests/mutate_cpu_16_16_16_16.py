#!/usr/bin/env python3
"""Mutation testing for cpu_16_16_16_16.

A passing test suite says nothing on its own: it could be passing because it
agrees with the implementation rather than with the document.  So this breaks
the implementation on purpose, one small edit at a time, and checks that the
suite notices.  A mutation that survives is a hole in the tests, not a bug in
the core.

Each mutation is a single exact string replacement that still compiles - a
flag swapped for its complement, a byte lane exchanged, a displacement not
doubled - and is chosen to be a mistake somebody could actually make while
reading docs/cpu_16_16_16_16.md.

The repository is copied to a scratch directory first, so nothing here can
touch the checked-in sources.  Verilog mutations need no rebuild because
iverilog compiles the sources at test time; the assembler ones rebuild.

usage:
    tests/mutate_cpu_16_16_16_16.py [--jobs N] [--keep]
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# (name, file, what it breaks, search, replace)
MUTATIONS = [
    # ---- the ALU
    ("and-becomes-or", "cpu_16_16_16_16.v", "and computes or",
     "8'h00: wr_zn(rd, rd_value & rs_value);",
     "8'h00: wr_zn(rd, rd_value | rs_value);"),
    ("adc-drops-carry", "cpu_16_16_16_16.v", "adc ignores C",
     "wire [16:0] alu_adc  = {1'b0, rd_value} + {1'b0, rs_value} + {16'b0, flag_c};",
     "wire [16:0] alu_adc  = {1'b0, rd_value} + {1'b0, rs_value};"),
    ("sbb-drops-borrow", "cpu_16_16_16_16.v", "sbb ignores C",
     "wire [16:0] alu_sbb  = {1'b0, rd_value} - {1'b0, rs_value} - {16'b0, flag_c};",
     "wire [16:0] alu_sbb  = {1'b0, rd_value} - {1'b0, rs_value};"),
    ("sub-operand-order", "cpu_16_16_16_16.v", "sub computes rs - rd",
     "wire [16:0] alu_sub  = {1'b0, rd_value} - {1'b0, rs_value};",
     "wire [16:0] alu_sub  = {1'b0, rs_value} - {1'b0, rd_value};"),
    ("div-by-zero", "cpu_16_16_16_16.v", "division by zero gives 0, not 0xffff",
     "(rs_value == 16'b0) ? 16'hffff : rd_value / rs_value",
     "(rs_value == 16'b0) ? 16'h0000 : rd_value / rs_value"),
    ("min-becomes-max", "cpu_16_16_16_16.v", "min and max exchanged",
     "8'h1b: wr_zn(rd, (rd_signed < rs_signed) ? rd_value : rs_value);",
     "8'h1b: wr_zn(rd, (rd_signed > rs_signed) ? rd_value : rs_value);"),
    ("sari-is-logical", "cpu_16_16_16_16.v", "sari shifts in zeroes",
     "8'h15: wr_zn(rd, rd_signed >>> shift_imm);",
     "8'h15: wr_zn(rd, rd_value >> shift_imm);"),
    ("sar-is-logical", "cpu_16_16_16_16.v", "sar shifts in zeroes",
     "8'h10: wr_zn(rd, rd_signed >>> shift_amount);",
     "8'h10: wr_zn(rd, rd_value >> shift_amount);"),
    ("shift-amount-unmasked", "cpu_16_16_16_16.v", "the shift amount is not masked to 4 bits",
     "wire [3:0] shift_amount = rs_value[3:0];",
     "wire [3:0] shift_amount = rs_value[7:4];"),
    ("sxb-zero-extends", "cpu_16_16_16_16.v", "sxb zero extends",
     "8'h1a: wr_zn(rd, {{8{rs_value[7]}}, rs_value[7:0]});",
     "8'h1a: wr_zn(rd, {8'b0, rs_value[7:0]});"),
    ("not-uses-rd", "cpu_16_16_16_16.v", "not inverts rd instead of rs",
     "8'h02: wr_zn(rd, ~rs_value);",
     "8'h02: wr_zn(rd, ~rd_value);"),

    # ---- the flags
    ("zero-flag-inverted", "cpu_16_16_16_16.v", "Z is set when the result is not zero",
     "        flag_z <= value == 16'b0;\n        flag_n <= value[15];",
     "        flag_z <= value != 16'b0;\n        flag_n <= value[15];"),
    ("negative-flag-wrong-bit", "cpu_16_16_16_16.v", "N reads bit 14",
     "        flag_z <= result[15:0] == 16'b0;\n        flag_n <= result[15];",
     "        flag_z <= result[15:0] == 16'b0;\n        flag_n <= result[14];"),
    ("overflow-add-rule", "cpu_16_16_16_16.v", "the add overflow rule is inverted",
     "ovf_add = (a[15] == b[15]) && (r[15] != a[15]);",
     "ovf_add = (a[15] != b[15]) && (r[15] != a[15]);"),
    ("overflow-sub-rule", "cpu_16_16_16_16.v", "the subtract overflow rule is inverted",
     "ovf_sub = (a[15] != b[15]) && (r[15] != a[15]);",
     "ovf_sub = (a[15] == b[15]) && (r[15] != a[15]);"),
    ("logic-writes-carry", "cpu_16_16_16_16.v", "andi also clears C, which section 4 forbids",
     "4'ha: wr_zn(rd, rd_value & imm_zx);",
     "4'ha: wr_zncv(rd, {1'b0, rd_value & imm_zx}, 1'b0);"),
    ("mov-writes-flags", "cpu_16_16_16_16.v", "mov writes Z and N, which section 4 forbids",
     "8'h0b: registers[rd] <= rs_value;",
     "8'h0b: wr_zn(rd, rs_value);"),
    ("cmp-writes-back", "cpu_16_16_16_16.v", "cmp writes its result to rd",
     "8'h0c: fl_zncv(alu_sub, ovf_sub(rd_value, rs_value, alu_sub[15:0]));",
     "8'h0c: wr_zncv(rd, alu_sub, ovf_sub(rd_value, rs_value, alu_sub[15:0]));"),
    ("sysreg-flag-order", "cpu_16_16_16_16.v", "rd_sys 2 returns the flags reversed",
     "4'h2: registers[rd] <= {12'b0, flag_v, flag_c, flag_n, flag_z};",
     "4'h2: registers[rd] <= {12'b0, flag_z, flag_n, flag_c, flag_v};"),

    # ---- the branch conditions
    ("blo-inverted", "cpu_16_16_16_16.v", "blo and bhs exchanged",
     "            4'h2: cond_met = flag_c;\n            4'h3: cond_met = !flag_c;",
     "            4'h2: cond_met = !flag_c;\n            4'h3: cond_met = flag_c;"),
    ("bhi-uses-or", "cpu_16_16_16_16.v", "bhi is an or instead of an and",
     "4'h8: cond_met = !flag_c && !flag_z;",
     "4'h8: cond_met = !flag_c || !flag_z;"),
    ("bge-uses-n", "cpu_16_16_16_16.v", "bge tests N alone, ignoring V",
     "4'ha: cond_met = flag_n == flag_v;",
     "4'ha: cond_met = !flag_n;"),
    ("ble-drops-zero", "cpu_16_16_16_16.v", "ble forgets the Z term",
     "4'hd: cond_met = flag_z || (flag_n != flag_v);",
     "4'hd: cond_met = flag_n != flag_v;"),

    # ---- control flow
    ("branch-disp-not-doubled", "cpu_16_16_16_16.v", "a branch displacement counts bytes",
     "wire [15:0] branch_target = PC_next + {{7{disp8[7]}}, disp8, 1'b0};",
     "wire [15:0] branch_target = PC_next + {{8{disp8[7]}}, disp8};"),
    ("branch-from-pc", "cpu_16_16_16_16.v", "a branch is relative to PC, not PC_next",
     "wire [15:0] branch_target = PC_next + {{7{disp8[7]}}, disp8, 1'b0};",
     "wire [15:0] branch_target = PC + {{7{disp8[7]}}, disp8, 1'b0};"),
    ("jump-disp-unsigned", "cpu_16_16_16_16.v", "disp12 is zero extended",
     "wire [15:0] jump_target = PC_next + {{3{disp12[11]}}, disp12, 1'b0};",
     "wire [15:0] jump_target = PC_next + {3'b0, disp12, 1'b0};"),
    ("call-links-pc", "cpu_16_16_16_16.v", "call links its own address",
     "                        registers[15] <= PC_next;\n                        PC <= {rs_value[15:1], 1'b0};",
     "                        registers[15] <= PC;\n                        PC <= {rs_value[15:1], 1'b0};"),
    ("ret-uses-r14", "cpu_16_16_16_16.v", "ret returns through r14",
     "wire [15:0] link_value = (wb_valid && wb_index == 4'hf) ? wb_value : registers[15];",
     "wire [15:0] link_value = (wb_valid && wb_index == 4'he) ? wb_value : registers[14];"),
    ("cycles-by-two", "cpu_16_16_16_16.v", "the cycle counter advances by two",
     "cycles <= cycles + 32'b1;",
     "cycles <= cycles + 32'd2;"),
    ("halt-does-not-stop", "cpu_16_16_16_16.v", "halt raises the flag but keeps running",
     "8'h20: halted_r <= 1'b1;",
     "8'h20: ;"),

    # ---- memory
    ("offset-counts-bytes", "cpu_16_16_16_16.v", "the ld/st displacement counts bytes",
     "wire [15:0] halfword_ea = m_rs_value + {11'b0, m_off, 1'b0};",
     "wire [15:0] halfword_ea = m_rs_value + {12'b0, m_off};"),
    ("store-byte-lanes-swapped", "cpu_16_16_16_16.v", "stb writes the other byte lane",
     "data_byte_enable <= byte_ea[0] ? 2'b10 : 2'b01;",
     "data_byte_enable <= byte_ea[0] ? 2'b01 : 2'b10;"),
    ("load-byte-lanes-swapped", "cpu_16_16_16_16.v", "ldb reads the other byte lane",
     "wire [7:0] wb_byte = data_byte_sel ? data_out_data[15:8] : data_out_data[7:0];",
     "wire [7:0] wb_byte = data_byte_sel ? data_out_data[7:0] : data_out_data[15:8];"),
    ("ldb-sign-extends", "cpu_16_16_16_16.v", "ldb sign extends, which is what sxb is for",
     "wire [15:0] wb_value = data_is_byte ? {8'b0, wb_byte} : data_out_data;",
     "wire [15:0] wb_value = data_is_byte ? {{8{wb_byte[7]}}, wb_byte} : data_out_data;"),
    ("no-load-forwarding", "cpu_16_16_16_16.v", "the load-use forwarding path is gone",
     "wire [15:0] rs_value   = (wb_valid && wb_index == rs)   ? wb_value : registers[rs];",
     "wire [15:0] rs_value   = registers[rs];"),
    ("no-load-forwarding-m", "cpu_16_16_16_16.v", "the forwarding path for M format reads is gone",
     "wire [15:0] m_rd_value = (wb_valid && wb_index == m_rd) ? wb_value : registers[m_rd];",
     "wire [15:0] m_rd_value = registers[m_rd];"),
    ("st-stores-base", "cpu_16_16_16_16.v", "st stores the base register instead of the value",
     "                    data_in_data <= m_rd_value;",
     "                    data_in_data <= m_rs_value;"),

    # ---- the immediate classes
    ("movi-zero-extends", "cpu_16_16_16_16.v", "movi zero extends",
     "4'h4: registers[rd] <= imm_sx;",
     "4'h4: registers[rd] <= imm_zx;"),
    ("movih-wrong-half", "cpu_16_16_16_16.v", "movih replaces the low byte",
     "4'h5: registers[rd] <= {imm8, rd_value[7:0]};",
     "4'h5: registers[rd] <= {rd_value[15:8], imm8};"),
    ("addi-zero-extends", "cpu_16_16_16_16.v", "addi zero extends its immediate",
     "wire [16:0] alu_addi = {1'b0, rd_value} + {1'b0, imm_sx};",
     "wire [16:0] alu_addi = {1'b0, rd_value} + {1'b0, imm_zx};"),
    ("andi-sign-extends", "cpu_16_16_16_16.v", "andi sign extends its immediate",
     "4'ha: wr_zn(rd, rd_value & imm_zx);",
     "4'ha: wr_zn(rd, rd_value & imm_sx);"),
    ("ori-sign-extends", "cpu_16_16_16_16.v", "ori sign extends its immediate",
     "4'hb: wr_zn(rd, rd_value | imm_zx);",
     "4'hb: wr_zn(rd, rd_value | imm_sx);"),

    # ---- the assembler, which has its own chances to be wrong
    ("asm-swaps-rs-rd", "asm_kernel.hpp", "the R format fields are exchanged",
     "            words[0] = (static_cast<uint32_t>(op) << 8) | (rs << 4) | rd;",
     "            words[0] = (static_cast<uint32_t>(op) << 8) | (rd << 4) | rs;"),
    ("asm-m-field-order", "asm_kernel.hpp", "ld/st place rd and rs the other way round",
     "            words[0] = (cls << 12) | (rd << 8) | (rs << 4) | off;",
     "            words[0] = (cls << 12) | (rs << 8) | (rd << 4) | off;"),
    ("asm-branch-from-here", "asm_kernel.hpp", "the displacement is measured from this instruction",
     "        int32_t disp = s.target - static_cast<int32_t>(s.address + 1);",
     "        int32_t disp = s.target - static_cast<int32_t>(s.address);"),
    ("asm-la-word-address", "asm_kernel.hpp", "la carries a word address, not a byte address",
     "            uint32_t byte_address = static_cast<uint32_t>(s.target) * 2u;",
     "            uint32_t byte_address = static_cast<uint32_t>(s.target);"),
    ("asm-imm-truncated", "asm_kernel.hpp", "the immediate is masked to seven bits",
     "        uint32_t imm = static_cast<uint32_t>(s.arg[2]) & 0xff;\n"
     "        uint32_t off = static_cast<uint32_t>(s.arg[2]) & 0xf;",
     "        uint32_t imm = static_cast<uint32_t>(s.arg[2]) & 0x7f;\n"
     "        uint32_t off = static_cast<uint32_t>(s.arg[2]) & 0xf;"),
    ("asm-imm-range-loose", "asm_kernel.hpp", "addi accepts an immediate the hardware misreads",
     "            if (v < -128 || v > 127) {\n                return ASM_ERR_IMM_RANGE;",
     "            if (v < -128 || v > 255) {\n                return ASM_ERR_IMM_RANGE;"),
    ("asm-branch-range-loose", "asm_kernel.hpp", "a branch out of range is accepted",
     "        int32_t limit = cpu1616_is_long_jump(l.opcode) ? 2048 : 128;",
     "        int32_t limit = cpu1616_is_long_jump(l.opcode) ? 2048 : 256;"),
    ("asm-cond-off-by-one", "asm_kernel.hpp", "bne encodes as beq",
     '            if (asm_tok_is(s, n, "bne"))    { *out = 0xc1; return true; }',
     '            if (asm_tok_is(s, n, "bne"))    { *out = 0xc0; return true; }'),
]

# The tests that are supposed to notice.  Everything else in the repository
# belongs to the other three cores and must stay green, which is checked once
# at the end rather than per mutation.
TEST_FILTER = "cpu_16_16_16_16|backends_cpu_16_16_16_16"


def run(cmd, cwd, quiet=True):
    return subprocess.run(cmd, cwd=cwd, shell=True,
                          stdout=subprocess.DEVNULL if quiet else None,
                          stderr=subprocess.DEVNULL if quiet else None).returncode


def ctest(work, jobs):
    """Return the names of the tests that failed."""
    out = subprocess.run(
        "ctest --test-dir build -R '%s' -j %d" % (TEST_FILTER, jobs),
        cwd=work, shell=True, capture_output=True, text=True)
    failed = []
    for line in out.stdout.splitlines():
        if "***Failed" in line or "***Exception" in line or "***Timeout" in line:
            m = re.search(r"Test\s+#\d+:\s+(\S+)", line)
            failed.append(m.group(1) if m else line.strip())
    return failed, out.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--keep", action="store_true",
                    help="leave the scratch copy behind for inspection")
    ap.add_argument("--only", default=None, help="run one mutation by name")
    args = ap.parse_args()

    work = tempfile.mkdtemp(prefix="mutate_cpu_16_16_16_16_")
    print("scratch copy: %s" % work)
    src = os.path.join(work, "cpu")
    shutil.copytree(ROOT, src, ignore=shutil.ignore_patterns("build", ".git"))

    print("=== configuring and building the unmutated copy")
    if run("cmake -S . -B build", src) != 0:
        print("cmake failed", file=sys.stderr)
        return 2
    if run("cmake --build build -j %d" % args.jobs, src) != 0:
        print("build failed", file=sys.stderr)
        return 2

    failed, code = ctest(src, args.jobs)
    if code != 0:
        print("the unmutated copy does not pass: %s" % failed, file=sys.stderr)
        return 2
    print("=== the unmutated copy is green")

    mutations = MUTATIONS
    if args.only:
        mutations = [m for m in MUTATIONS if m[0] == args.only]
        if not mutations:
            print("no such mutation: %s" % args.only, file=sys.stderr)
            return 2

    caught = []
    escaped = []
    broken = []
    for name, filename, what, search, replace in mutations:
        path = os.path.join(src, filename)
        original = open(path).read()
        if original.count(search) != 1:
            print("  BROKEN   %-28s (the pattern matches %d times)"
                  % (name, original.count(search)))
            broken.append(name)
            continue
        open(path, "w").write(original.replace(search, replace))

        rebuilt = True
        if filename.endswith((".hpp", ".cpp", ".hip")):
            rebuilt = run("cmake --build build -j %d" % args.jobs, src) == 0

        if not rebuilt:
            # A mutation that does not compile is not a mutation: the
            # compiler caught it, which is not what the tests are for.
            print("  BROKEN   %-28s (does not compile)" % name)
            broken.append(name)
        else:
            failed, code = ctest(src, args.jobs)
            if code != 0:
                caught.append((name, what, failed))
                print("  caught   %-28s %-52s by %s"
                      % (name, what, ", ".join(failed[:3]) or "?"))
            else:
                escaped.append((name, what))
                print("  ESCAPED  %-28s %s" % (name, what))

        open(path, "w").write(original)
        if filename.endswith((".hpp", ".cpp", ".hip")):
            run("cmake --build build -j %d" % args.jobs, src)

    print()
    print("%d mutations: %d caught, %d escaped, %d unusable"
          % (len(mutations), len(caught), len(escaped), len(broken)))
    for name, what in escaped:
        print("  escaped: %s - %s" % (name, what))

    if not args.keep:
        shutil.rmtree(work)
    return 1 if escaped or broken else 0


sys.exit(main())
