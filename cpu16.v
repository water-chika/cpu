`include "memory.v"

module cpu_inst16_data8(
    input clk
);

parameter INST_WIDTH = 16;

reg [7:0] IP; // Because program memory has latency,
              // IP point to next instruction address.
reg stall;
reg [7:0] stall_counter; // If it needs more than 1 stall clock

initial begin
    stall = 1'b0;
    stall_counter = 0;
end

initial begin
    IP = 0;
end

wire program_read_enable;
wire [7:0] program_address;
wire [INST_WIDTH-1:0] program_out_data;

// The second program memory port, which is what ld_p and st_p run on.  The
// fetch owns port A and never gives it up, so a program can read or write its
// own instruction memory without ever stalling the fetch.
wire program_b_enable;
reg program_b_write_enable;
reg program_b_read_enable;
reg program_b_half;
reg [7:0] program_b_address;
reg [7:0] program_b_in_data;
wire [7:0] program_b_out_data;
reg [2:0] program_b_dst;

program_memory program(
    .clk(clk),
    .a_enable(program_read_enable),
    .a_address(program_address),
    .a_out_data(program_out_data),
    .b_enable(program_b_enable),
    .b_write_enable(program_b_write_enable),
    .b_half(program_b_half),
    .b_address(program_b_address),
    .b_in_data(program_b_in_data),
    .b_out_data(program_b_out_data)
);

assign program_b_enable = 1'b1;

initial begin
    program_b_write_enable = 1'b0;
    program_b_read_enable = 1'b0;
    program_b_half = 1'b0;
    program_b_address = 0;
    program_b_in_data = 0;
    program_b_dst = 0;
end

wire data_enable;
reg data_write_enable;
reg data_read_enable;
reg [7:0] data_address;
reg [7:0] data_in_data;
wire [7:0] data_out_data;
memory data(
    .clk(clk),
    .write_enable(data_write_enable),
    .enable(data_enable),
    .address(data_address),
    .in_data(data_in_data),
    .out_data(data_out_data)
);

assign data_enable = 1'b1;

initial begin
    data_write_enable = 1'b0;
end

wire [INST_WIDTH-1:0] Inst;

assign program_address = IP;
assign program_read_enable = 1'b1;
assign Inst = stall ? {INST_WIDTH{1'b0}} : program_out_data;

reg [7:0] registers[7:0];

initial begin:INIT_REGS
    integer i;
    for (i = 0; i < 8; i=i+1) begin
        registers[i] <= 0;
    end
end

// Instruction layout:
//
//   |f e d c b a 9|8 7 6|5 4 3|2 1 0|
//   |   Opcode    | Arg0| Arg1| Arg2|
//
// For the data process instructions Arg0 is src0, Arg1 is src1 and Arg2 is dst.
// The immediate and shift instructions reinterpret Arg0/Arg1 as an immediate
// value and a shift amount; see README.md.
wire [6:0] opcode;
wire [2:0] src0;
wire [2:0] src1;
wire [2:0] dst;
wire [2:0] imm3;
wire [2:0] imm_shift;
wire [7:0] imm;
wire [2:0] shift_imm;

assign opcode = Inst[15:9];
assign src0 = Inst[8:6];
assign src1 = Inst[5:3];
assign dst = Inst[2:0];
assign imm3 = Inst[8:6];
assign imm_shift = Inst[5:3];
assign imm = {5'b0, imm3} << imm_shift;
assign shift_imm = Inst[5:3];

reg [2:0] data_dst;

// The carry flag.  It is a single bit of processor state that lives outside
// the register file, written only by add, adc, sub and sbb, and read only by
// adc and sbb.  For add and adc it is the carry out of bit 7; for sub and sbb
// it is the borrow out of bit 7.  Nothing else disturbs it, so a multi byte
// add or subtract can be written as one add/sub followed by as many adc/sbb
// as it needs.
reg carry;
reg [8:0] alu; // 9 bits: [7:0] is the result, [8] is the carry or borrow out

initial begin
    data_dst = 0;
    data_read_enable = 1'b0;
    carry = 1'b0;
    alu = 9'b0;
end

always @(posedge clk) begin

    // delay to wait memory operation
    #1 if (data_write_enable) begin
        data_write_enable = 1'b0;
    end
    if (data_read_enable) begin
        registers[data_dst] = data_out_data;
        data_read_enable = 1'b0;
    end
    if (program_b_write_enable) begin
        program_b_write_enable = 1'b0;
    end
    if (program_b_read_enable) begin
        registers[program_b_dst] = program_b_out_data;
        program_b_read_enable = 1'b0;
    end

    if (stall == 1'b1) begin
        if (stall_counter == 0) begin
            stall = 1'b0;
        end
        else begin
            stall_counter = stall_counter-1;
        end
    end

    IP = IP;

    if (~stall) begin
        IP = IP + 1;
    end

    // delay to wait memory operation
    #1 case (opcode)
        0: registers[dst] <= registers[src0] & registers[src1];
        1: registers[dst] <= registers[src0] | registers[src1];
        2: registers[dst] <= ~registers[src0];
        3: registers[dst] <= registers[src0] ^ registers[src1];
        4:
        begin
            alu = registers[src0] + registers[src1];
            registers[dst] <= alu[7:0];
            carry <= alu[8];
        end
        5:
        begin
            alu = registers[src0] + registers[src1] + carry;
            registers[dst] <= alu[7:0];
            carry <= alu[8];
        end
        6:
        begin
            alu = registers[src0] - registers[src1];
            registers[dst] <= alu[7:0];
            carry <= alu[8];
        end
        7:
        begin
            alu = registers[src0] - registers[src1] - carry;
            registers[dst] <= alu[7:0];
            carry <= alu[8];
        end
        8: registers[dst] <= -registers[src0];
        9: registers[dst] <= registers[src0] * registers[src1];
        10: registers[dst] <= registers[src0] / registers[src1];
        11: registers[dst] <= registers[src0];
        12: registers[dst] <= imm;
        13: registers[dst] <= registers[dst] | imm;
        14: registers[dst] <= registers[src0] << shift_imm;
        15: registers[dst] <= registers[src0] >> shift_imm;
        16: registers[dst] <= (registers[src0] << shift_imm)
                            | (registers[src0] >> (8 - shift_imm));
        17: registers[dst] <= (registers[src0] >> shift_imm)
                            | (registers[src0] << (8 - shift_imm));
        18: registers[dst] <= $signed(registers[src0]) >>> shift_imm;
        19: registers[dst] <= IP + imm;

        32:
            if (registers[src0] != 0) begin
                IP = registers[src1];
                stall = 1'b1;
            end
        33:
            if (registers[src0] == 0) begin
                IP = registers[src1];
                stall = 1'b1;
            end
        34:
            begin
            IP = registers[src1];
            stall = 1'b1;
            end
        35:
            if ($signed(registers[src0]) < 0) begin
                IP = registers[src1];
                stall = 1'b1;
            end
        36:
            if ($signed(registers[src0]) > 0) begin
                IP = registers[src1];
                stall = 1'b1;
            end

        64:
        begin
            data_address = registers[src1];
            data_dst = dst;
            data_read_enable = 1'b1;
        end
        65:
        begin
            data_address = registers[src1];
            data_dst = dst;
            data_write_enable = 1'b1;
            data_in_data = registers[src0];
        end
        66:
        begin
            data_address = registers[src1];
            data_dst = dst;
            data_write_enable = 1'b1;
            data_in_data = 8'b00000000;
        end
        67:
        begin
            data_address = registers[src1];
            data_dst = dst;
            data_write_enable = 1'b1;
            data_read_enable = 1'b1;
            data_in_data = registers[dst];
        end
        68:
        begin
            program_b_address = registers[src1];
            program_b_half = src0[0];
            program_b_dst = dst;
            program_b_read_enable = 1'b1;
        end
        69:
        begin
            program_b_address = registers[src1];
            program_b_half = dst[0];
            program_b_in_data = registers[src0];
            program_b_write_enable = 1'b1;
        end
        default: $display("unknown opcode %b", opcode);
    endcase
end

endmodule
