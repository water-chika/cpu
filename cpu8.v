`include "memory.v"

module cpu_inst8_data8(
    input clk
);

parameter INST_WIDTH = 8;

reg [7:0] IP; // Because program memory has latency,
              // IP point to next instruction address.
reg [7:0] instruction_pointer_1;
reg stall;
reg [7:0] stall_counter; // If it needs more than 1 stall clock

initial begin
    IP = 0;
    instruction_pointer_1 = 0;
    stall = 1'b0;
    stall_counter = 0;
end

wire program_write_enable;
wire program_read_enable;
wire [7:0] program_address;
wire [INST_WIDTH-1:0] program_in_data;
wire [INST_WIDTH-1:0] program_out_data;

memory #(.DATA_WIDTH(INST_WIDTH)) program(
    .clk(clk),
    .write_enable(program_write_enable),
    .enable(program_read_enable),
    .address(program_address),
    .in_data(program_in_data),
    .out_data(program_out_data)
);

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

wire [INST_WIDTH:0] Inst;

assign program_address = IP;
assign program_read_enable = 1'b1;
assign program_write_enable = 1'b0;
assign program_in_data = 8'b00000000;
assign Inst = stall ? 8'b00000000 : program_out_data;

reg [7:0] registers[7:0];
reg [0:0] condition;

initial begin:INIT_REGS
    integer i;
    for (i = 0; i < 8; i=i+1) begin
        registers[i] <= 0;
    end
    condition <= 1'b1;
end

wire [4:0] opcode;
wire [2:0] arg;
wire [2:0] src0;
reg [2:0] src1;
wire [2:0] dst;
wire [2:0] dst1;
wire [7:0] imm;
wire [2:0] shift_imm;
assign opcode = Inst[7:3];
assign src0 = Inst[2:0];
assign dst = src0;
assign dst1 = src1;
assign imm = Inst[2:0];
assign shift_imm = Inst[2:0];
assign arg = Inst[2:0];

reg [2:0] data_dst;


initial begin
    data_dst = 0;
    src1 = 0;
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

    if (condition) begin
    // delay to wait memory operation
    #1 case (opcode)
        0: registers[dst]     <= registers[src0] & registers[src1];
        1: registers[dst]     <= registers[src0] | registers[src1];
        2: registers[dst]     <= 8'b11111111     ^ registers[src1];
        3: registers[dst]     <= registers[src0] ^ registers[src1];
        4: registers[dst]     <= registers[src0] + registers[src1];
        5: registers[dst]     <= registers[src0] - registers[src1];
        6: registers[dst]     <= 8'b00000000     - registers[src1];
        7: registers[dst]     <= registers[src0] * registers[src1];
        8: registers[dst]     <= registers[src0] / registers[src1];
        9: registers[dst]     <= 8'b00000000     | registers[src1];
        10: registers[dst1]   <= registers[src0] | 8'b00000000;
        11: registers[dst1]   <=           imm;
        12: registers[dst1]   <= registers[src1] << shift_imm;
        13: registers[dst1]   <= registers[src1] >> shift_imm;

        14: condition = registers[src0] != 0;
        15: condition = registers[src0] == 0;
        16: condition = registers[src0] < 0;
        17: condition = registers[src0] > 0;
        18:
            begin
                case (arg)
                    0: condition = 1;
                    1:
                        begin
                            IP = instruction_pointer_1;
                            stall = 1'b1;
                        end
                endcase
            end

        19: instruction_pointer_1 = registers[src0];
        20: data_address = registers[src0];

        24:
        begin
            data_dst = dst;
            data_read_enable = 1'b1;
        end
        25:
        begin
            data_write_enable = 1'b1;
            data_in_data = registers[src0];
        end
        26:
        begin
            data_write_enable = 1'b1;
            data_in_data = 8'b00000000;
        end
        27:
        begin
            data_dst = dst;
            data_write_enable = 1'b1;
            data_read_enable = 1'b1;
            data_in_data = registers[src0];
        end

        31: src1 = arg;
        default: $display("unknown opcode %b", opcode);
    endcase
    end
    if (opcode == 18) condition = 1;
end

endmodule
