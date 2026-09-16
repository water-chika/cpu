`include "cpu_16_16_16_16_memory.v"

// cpu_16_16_16_16 - the core specified by docs/cpu_16_16_16_16.md.
//
// The name is this repository's convention read out in order: instruction
// width / data width / register count / PC width.  So a 16 bit instruction
// word over a 16 bit data path, 16 registers, and a 16 bit program counter
// over 64 KiB.  Under the same convention cpu16.v's `cpu_inst16_data8` is
// cpu_16_8_8_8 and gpu16.v's scalar unit is cpu_32_32_16_16.
//
// This file is an implementation of that document and not the other way
// round.  Where the two disagree, this file is wrong.  In particular:
//
//   * the instruction is two address (`op rd, rs` computes rd = rd op rs),
//     because 16 bits cannot hold three 4 bit register fields and an opcode;
//   * `Inst[15:12]` is the class.  0x0-0x3 are the register-register format,
//     whose opcode is the whole top byte; the other twelve classes are the
//     immediate, memory and control formats, and 0xf is reserved;
//   * there are four flags, Z N C V, and C is a *borrow* after a subtract,
//     which is the convention cpu16.v's `alu_sub[8]` already uses;
//   * every instruction retires in one cycle, taken branches and loads
//     included.  cpu16.v carries a stall/stall_counter pair for a multi
//     cycle stall it never takes - `stall_active` there is provably always
//     0 - and this core does not copy the dead machinery.
//
// The style is cpu16.v's, deliberately: one clocked block, non blocking
// assignments only, no `#` delays, no `initial`, an asynchronous reset that
// does what silicon does, and a loader port on each memory so that the path
// a board uses to get a program in is the path the tests exercise.
//
// The one piece of cpu16.v that is kept in full is the load write back.  A
// load registers its address on the edge that retires it and the value
// arrives on the next edge, at the same instant that the following
// instruction is decoded - so the read side has a forwarding multiplexer
// (`fwd`) and the write back is a non blocking assignment that the ALU's own
// write overrides if they collide.
module cpu_16_16_16_16 #(
    // The architecture is 16 bits of each; these exist so that a board can
    // build a smaller memory, exactly as gpu16.v parameterises its program
    // memory.  A smaller build aliases rather than traps.
    parameter PROGRAM_ADDR_WIDTH = 15,   // instruction *word* address bits
    parameter DATA_ADDR_WIDTH = 16       // data *byte* address bits
) (
    input clk,
    input reset,

    // Instruction memory loader: one 16 bit word per cycle, word addressed.
    input prog_load_enable,
    input [PROGRAM_ADDR_WIDTH-1:0] prog_load_address,
    input [15:0] prog_load_data,

    // Data memory loader: one 16 bit word per cycle, word addressed.  Words
    // rather than bytes because the array is words; a byte granular loader
    // would need the byte enables and no host wants that.
    input data_load_enable,
    input [DATA_ADDR_WIDTH-2:0] data_load_address,
    input [15:0] data_load_data,

    // High once the core has executed `halt`.  A testbench uses it to tell a
    // program that finished from one that ran into the weeds; see
    // docs/cpu_16_16_16_16.md section 7.
    output halted
);

// ------------------------------------------------------------ architectural state

reg [15:0] registers[0:15];
reg [15:0] PC;          // a byte address, always even
reg flag_z;
reg flag_n;
reg flag_c;             // carry out of bit 15, or borrow out of bit 15
reg flag_v;             // signed overflow
reg [31:0] cycles;      // one per executed instruction, section 7
reg halted_r;

assign halted = halted_r;

integer i;

// ------------------------------------------------------------ instruction memory

wire [15:0] Inst;

program_memory_16 #(.ADDR_WIDTH(PROGRAM_ADDR_WIDTH)) program(
    .clk(clk),
    .enable(1'b1),
    .address(PC[PROGRAM_ADDR_WIDTH:1]),
    .out_data(Inst),
    .load_enable(prog_load_enable),
    .load_address(prog_load_address),
    .load_data(prog_load_data)
);

// ------------------------------------------------------------ data memory

reg data_read_enable;
reg data_write_enable;
reg [1:0] data_byte_enable;
reg [DATA_ADDR_WIDTH-2:0] data_address;
reg [15:0] data_in_data;
reg [3:0] data_dst;
reg data_is_byte;       // the pending load is a byte load
reg data_byte_sel;      // ... of the high byte of its word
wire [15:0] data_out_data;

// The loader's multiplexer in front of the one port, as cpu16.v does it: the
// host holds the core in reset while it loads, so this is a mux rather than
// a second write port.
wire data_mem_write_enable = data_load_enable | data_write_enable;
wire [1:0] data_mem_byte_enable = data_load_enable ? 2'b11 : data_byte_enable;
wire [DATA_ADDR_WIDTH-2:0] data_mem_address =
    data_load_enable ? data_load_address : data_address;
wire [15:0] data_mem_in_data = data_load_enable ? data_load_data : data_in_data;

byte_memory_16 #(.ADDR_WIDTH(DATA_ADDR_WIDTH)) data(
    .clk(clk),
    .enable(1'b1),
    .write_enable(data_mem_write_enable),
    .byte_enable(data_mem_byte_enable),
    .address(data_mem_address),
    .in_data(data_mem_in_data),
    .out_data(data_out_data)
);

// ------------------------------------------------------------ decode

// Instruction layout, docs/cpu_16_16_16_16.md section 2:
//
//    |f e d c|b a 9 8|7 6 5 4|3 2 1 0|
//  R |0 0 op6        |  rs   |  rd   |   class 0x0-0x3, opcode = Inst[15:8]
//  I |class  |    imm8       |  rd   |   classes 0x4-0x7, 0xa, 0xb
//  M |class  |  rd   |  rs   | off4  |   classes 0x8, 0x9
//  B |1 1 0 0| cond  |    disp8      |   class 0xc
//  J |1 1 0 1|      disp12           |   class 0xd  (jmp)
//  J |1 1 1 0|      disp12           |   class 0xe  (call)
//    |1 1 1 1|         reserved      |   class 0xf
wire [3:0] iclass = Inst[15:12];
wire [7:0] opcode = Inst[15:8];
wire [3:0] rs = Inst[7:4];
wire [3:0] rd = Inst[3:0];
wire [3:0] shift_imm = Inst[7:4];       // shli/shri/sari/roli/rori
wire [3:0] sysreg = Inst[7:4];          // rd_sys
wire [7:0] imm8 = Inst[11:4];
wire [3:0] m_rd = Inst[11:8];
wire [3:0] m_rs = Inst[7:4];
wire [3:0] m_off = Inst[3:0];
wire [3:0] cond = Inst[11:8];
wire [7:0] disp8 = Inst[7:0];
wire [11:0] disp12 = Inst[11:0];

wire [15:0] imm_sx = {{8{imm8[7]}}, imm8};
wire [15:0] imm_zx = {8'b0, imm8};

// ------------------------------------------------------------ operand read

// The load write back lands on this edge, at the same instant the
// instruction below is decoded, so every operand read goes through `fwd`.
wire wb_valid = data_read_enable;
wire [3:0] wb_index = data_dst;
wire [7:0] wb_byte = data_byte_sel ? data_out_data[15:8] : data_out_data[7:0];
wire [15:0] wb_value = data_is_byte ? {8'b0, wb_byte} : data_out_data;

// Written out per field rather than through a function, which is cpu16.v's
// own shape: a continuous assignment that reads one word of a register array
// is a pattern every simulator agrees about, and a function call in the same
// place is not.
wire [15:0] rs_value   = (wb_valid && wb_index == rs)   ? wb_value : registers[rs];
wire [15:0] rd_value   = (wb_valid && wb_index == rd)   ? wb_value : registers[rd];
wire [15:0] m_rs_value = (wb_valid && wb_index == m_rs) ? wb_value : registers[m_rs];
wire [15:0] m_rd_value = (wb_valid && wb_index == m_rd) ? wb_value : registers[m_rd];
// `ret` reads r15, and a load into r15 immediately before it must be seen.
wire [15:0] link_value = (wb_valid && wb_index == 4'hf) ? wb_value : registers[15];

// ------------------------------------------------------------ ALU

// 17 bits wide: [15:0] is the result and [16] is the carry out of bit 15, or
// for the subtracting forms the borrow out of bit 15.
wire [16:0] alu_add  = {1'b0, rd_value} + {1'b0, rs_value};
wire [16:0] alu_adc  = {1'b0, rd_value} + {1'b0, rs_value} + {16'b0, flag_c};
wire [16:0] alu_sub  = {1'b0, rd_value} - {1'b0, rs_value};
wire [16:0] alu_sbb  = {1'b0, rd_value} - {1'b0, rs_value} - {16'b0, flag_c};
wire [16:0] alu_neg  = 17'b0 - {1'b0, rs_value};
wire [16:0] alu_addi = {1'b0, rd_value} + {1'b0, imm_sx};
wire [16:0] alu_cmpi = {1'b0, rd_value} - {1'b0, imm_sx};

// Signed overflow.  For a + b -> r it is "the operands agreed about their
// sign and the result did not"; for a - b -> r, "the operands disagreed and
// the result took the subtrahend's side".  neg is 0 - rs, which is the
// subtract rule with a = 0, and overflows exactly at rs == 0x8000.
function ovf_add;
    input [15:0] a;
    input [15:0] b;
    input [15:0] r;
    begin
        ovf_add = (a[15] == b[15]) && (r[15] != a[15]);
    end
endfunction

function ovf_sub;
    input [15:0] a;
    input [15:0] b;
    input [15:0] r;
    begin
        ovf_sub = (a[15] != b[15]) && (r[15] != a[15]);
    end
endfunction

wire [3:0] shift_amount = rs_value[3:0];
wire [15:0] tst_result = rd_value & rs_value;
wire [15:0] div_result = (rs_value == 16'b0) ? 16'hffff : rd_value / rs_value;
wire signed [15:0] rd_signed = rd_value;
wire signed [15:0] rs_signed = rs_value;

// The branch conditions of section 3.4.  Condition 0xf is reserved and is
// handled by the decode, not here.
function cond_met;
    input [3:0] c;
    begin
        case (c)
            4'h0: cond_met = flag_z;
            4'h1: cond_met = !flag_z;
            4'h2: cond_met = flag_c;
            4'h3: cond_met = !flag_c;
            4'h4: cond_met = flag_n;
            4'h5: cond_met = !flag_n;
            4'h6: cond_met = flag_v;
            4'h7: cond_met = !flag_v;
            4'h8: cond_met = !flag_c && !flag_z;
            4'h9: cond_met = flag_c || flag_z;
            4'ha: cond_met = flag_n == flag_v;
            4'hb: cond_met = flag_n != flag_v;
            4'hc: cond_met = !flag_z && (flag_n == flag_v);
            4'hd: cond_met = flag_z || (flag_n != flag_v);
            4'he: cond_met = 1'b1;
            default: cond_met = 1'b0;
        endcase
    end
endfunction

// ------------------------------------------------------------ control flow

wire [15:0] PC_next = PC + 16'd2;
// A displacement counts instruction *words* from the following instruction,
// so it is doubled to reach a byte address.
wire [15:0] branch_target = PC_next + {{7{disp8[7]}}, disp8, 1'b0};
wire [15:0] jump_target = PC_next + {{3{disp12[11]}}, disp12, 1'b0};

// The effective addresses.  ld/st ignore bit 0 of the sum (section 5), which
// costs nothing here because only the word address is kept.
wire [15:0] halfword_ea = m_rs_value + {11'b0, m_off, 1'b0};
wire [15:0] byte_ea = rs_value;

// ------------------------------------------------------------ write helpers

// A task that writes a register also writes Z and N, because every
// instruction in this ISA that produces an ALU result does (section 4).
task wr_zn;
    input [3:0] index;
    input [15:0] value;
    begin
        registers[index] <= value;
        flag_z <= value == 16'b0;
        flag_n <= value[15];
    end
endtask

task fl_zncv;
    input [16:0] result;
    input overflow;
    begin
        flag_z <= result[15:0] == 16'b0;
        flag_n <= result[15];
        flag_c <= result[16];
        flag_v <= overflow;
    end
endtask

task wr_zncv;
    input [3:0] index;
    input [16:0] result;
    input overflow;
    begin
        registers[index] <= result[15:0];
        fl_zncv(result, overflow);
    end
endtask

// ------------------------------------------------------------ the machine

always @(posedge clk or posedge reset) begin
    if (reset) begin
        PC <= 16'b0;
        flag_z <= 1'b0;
        flag_n <= 1'b0;
        flag_c <= 1'b0;
        flag_v <= 1'b0;
        cycles <= 32'b0;
        halted_r <= 1'b0;
        data_read_enable <= 1'b0;
        data_write_enable <= 1'b0;
        data_byte_enable <= 2'b0;
        data_address <= {(DATA_ADDR_WIDTH-1){1'b0}};
        data_in_data <= 16'b0;
        data_dst <= 4'b0;
        data_is_byte <= 1'b0;
        data_byte_sel <= 1'b0;
        for (i = 0; i < 16; i = i + 1) begin
            registers[i] <= 16'b0;
        end
    end
    else begin
        // A memory operation lasts exactly one edge, so every enable falls
        // again unless this cycle's instruction raises it below.  This is
        // outside the halt test on purpose: a load issued by the instruction
        // before a `halt` still writes its register on the halting edge, and
        // must not go on doing so for ever afterwards.
        data_read_enable <= 1'b0;
        data_write_enable <= 1'b0;

        // The load write back.  If the instruction below writes the same
        // register its assignment comes later in this block and therefore
        // wins.
        if (wb_valid) begin
            registers[wb_index] <= wb_value;
        end

        if (!halted_r) begin
            cycles <= cycles + 32'b1;
            PC <= PC_next;

            case (iclass)
            // ------------------------------------------- R, classes 0x0-0x3
            4'h0, 4'h1, 4'h2, 4'h3:
                case (opcode)
                8'h00: wr_zn(rd, rd_value & rs_value);
                8'h01: wr_zn(rd, rd_value | rs_value);
                8'h02: wr_zn(rd, ~rs_value);
                8'h03: wr_zn(rd, rd_value ^ rs_value);
                8'h04: wr_zncv(rd, alu_add, ovf_add(rd_value, rs_value, alu_add[15:0]));
                8'h05: wr_zncv(rd, alu_adc, ovf_add(rd_value, rs_value, alu_adc[15:0]));
                8'h06: wr_zncv(rd, alu_sub, ovf_sub(rd_value, rs_value, alu_sub[15:0]));
                8'h07: wr_zncv(rd, alu_sbb, ovf_sub(rd_value, rs_value, alu_sbb[15:0]));
                8'h08: wr_zncv(rd, alu_neg, ovf_sub(16'b0, rs_value, alu_neg[15:0]));
                8'h09: wr_zn(rd, rd_value * rs_value);
                8'h0a: wr_zn(rd, div_result);
                8'h0b: registers[rd] <= rs_value;
                8'h0c: fl_zncv(alu_sub, ovf_sub(rd_value, rs_value, alu_sub[15:0]));
                8'h0d:
                    begin
                        flag_z <= tst_result == 16'b0;
                        flag_n <= tst_result[15];
                    end
                8'h0e: wr_zn(rd, rd_value << shift_amount);
                8'h0f: wr_zn(rd, rd_value >> shift_amount);
                8'h10: wr_zn(rd, rd_signed >>> shift_amount);
                8'h11: wr_zn(rd, (rd_value << shift_amount) |
                                 (rd_value >> (16 - shift_amount)));
                8'h12: wr_zn(rd, (rd_value >> shift_amount) |
                                 (rd_value << (16 - shift_amount)));
                8'h13: wr_zn(rd, rd_value << shift_imm);
                8'h14: wr_zn(rd, rd_value >> shift_imm);
                8'h15: wr_zn(rd, rd_signed >>> shift_imm);
                8'h16: wr_zn(rd, (rd_value << shift_imm) |
                                 (rd_value >> (16 - shift_imm)));
                8'h17: wr_zn(rd, (rd_value >> shift_imm) |
                                 (rd_value << (16 - shift_imm)));
                8'h18:      // ldb rd, rs
                    begin
                        data_address <= byte_ea[DATA_ADDR_WIDTH-1:1];
                        data_dst <= rd;
                        data_is_byte <= 1'b1;
                        data_byte_sel <= byte_ea[0];
                        data_read_enable <= 1'b1;
                    end
                8'h19:      // stb rd, rs
                    begin
                        data_address <= byte_ea[DATA_ADDR_WIDTH-1:1];
                        data_write_enable <= 1'b1;
                        data_byte_enable <= byte_ea[0] ? 2'b10 : 2'b01;
                        data_in_data <= {rd_value[7:0], rd_value[7:0]};
                    end
                8'h1a: wr_zn(rd, {{8{rs_value[7]}}, rs_value[7:0]});
                8'h1b: wr_zn(rd, (rd_signed < rs_signed) ? rd_value : rs_value);
                8'h1c: wr_zn(rd, (rd_signed > rs_signed) ? rd_value : rs_value);
                8'h1d: PC <= {rs_value[15:1], 1'b0};
                8'h1e:
                    begin
                        registers[15] <= PC_next;
                        PC <= {rs_value[15:1], 1'b0};
                    end
                8'h1f:
                    case (sysreg)
                        4'h0: registers[rd] <= cycles[15:0];
                        4'h1: registers[rd] <= cycles[31:16];
                        4'h2: registers[rd] <= {12'b0, flag_v, flag_c, flag_n, flag_z};
                        default: $display("unknown opcode %h", Inst);
                    endcase
                8'h20: halted_r <= 1'b1;
                8'h21: ;    // nop
                8'h22: PC <= {link_value[15:1], 1'b0};
                default: $display("unknown opcode %h", Inst);
                endcase

            // ------------------------------------------- I, six classes
            4'h4: registers[rd] <= imm_sx;
            4'h5: registers[rd] <= {imm8, rd_value[7:0]};
            4'h6: wr_zncv(rd, alu_addi, ovf_add(rd_value, imm_sx, alu_addi[15:0]));
            4'h7: fl_zncv(alu_cmpi, ovf_sub(rd_value, imm_sx, alu_cmpi[15:0]));
            4'ha: wr_zn(rd, rd_value & imm_zx);
            4'hb: wr_zn(rd, rd_value | imm_zx);

            // ------------------------------------------- M, ld and st
            4'h8:
                begin
                    data_address <= halfword_ea[DATA_ADDR_WIDTH-1:1];
                    data_dst <= m_rd;
                    data_is_byte <= 1'b0;
                    data_byte_sel <= 1'b0;
                    data_read_enable <= 1'b1;
                end
            4'h9:
                begin
                    data_address <= halfword_ea[DATA_ADDR_WIDTH-1:1];
                    data_write_enable <= 1'b1;
                    data_byte_enable <= 2'b11;
                    data_in_data <= m_rd_value;
                end

            // ------------------------------------------- B and J
            4'hc:
                if (cond == 4'hf) begin
                    $display("unknown opcode %h", Inst);
                end
                else if (cond_met(cond)) begin
                    PC <= branch_target;
                end
            4'hd: PC <= jump_target;
            4'he:
                begin
                    registers[15] <= PC_next;
                    PC <= jump_target;
                end

            default: $display("unknown opcode %h", Inst);
            endcase
        end
    end
end

endmodule
