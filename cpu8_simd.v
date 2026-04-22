`include "memory.v"

module cpu_inst8_data8(
    input clk
);

parameter INST_WIDTH = 8;
parameter LANE_COUNT = 32; // SIMD32

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
reg [7:0] data_address[LANE_COUNT-1:0];
reg [7:0] data_in_data[LANE_COUNT-1:0];
wire [7:0] data_out_data[LANE_COUNT-1:0];
memory data(
    .clk(clk),
    .write_enable(data_write_enable[]),
    .enable(data_enable[]),
    .address(data_address[]),
    .in_data(data_in_data[]),
    .out_data(data_out_data[])
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

reg [7:0] registers[SIMD_WIDTH-1:0][7:0];

initial begin:INIT_REGS
    integer lane;
    integer i;
    for (lane = 0; lane < LANE_COUNT; lane=lane+1) begin
    for (i = 0; i < 8; i=i+1) begin
        registers[lane][i] <= 0;
    end
    end
end

wire [4:0] opcode;
wire [2:0] arg;
wire [2:0] src0;
reg [2:0] src1;
wire [2:0] dst;
wire dst1;
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
        registers[lane][data_dst] = data_out_data;
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

    // delay to wait memory operation
    #1 case (opcode)
        0:
        begin
            integer lane;
            for (lane=0; lane < LANE_COUNT; lane=lane+1) begin
                registers[lane][dst]     <= registers[lane][src0] & registers[lane][src1];
            end
        end
        1:
        begin
            integer lane;
            for (lane=0; lane < LANE_COUNT; lane=lane+1) begin
                registers[lane][dst]     <= registers[lane][src0] | registers[lane][src1];
            end
        end
        2:
        begin
            integer lane;
            for (lane=0; lane < LANE_COUNT; lane=lane+1) begin
                registers[lane][dst]     <= 8'b11111111     ^ registers[lane][src1];
            end
        end
        3:
        begin
            integer lane;
            for (lane=0; lane < LANE_COUNT; lane=lane+1) begin
                registers[lane][dst]     <= registers[lane][src0] ^ registers[lane][src1];
            end
        end
        4:
        begin
            integer lane;
            for (lane=0; lane < LANE_COUNT; lane=lane+1) begin
                registers[lane][dst]     <= registers[lane][src0] + registers[lane][src1];
            end
        end
        5:
        begin
            integer lane;
            for (lane=0; lane < LANE_COUNT; lane=lane+1) begin
                registers[lane][dst]     <= registers[lane][src0] - registers[lane][src1];
            end
        end
        6:
        begin
            integer lane;
            for (lane=0; lane < LANE_COUNT; lane=lane+1) begin
                registers[lane][dst]     <= 8'b00000000     - registers[lane][src1];
            end
        end
        7:
        begin
            integer lane;
            for (lane=0; lane < LANE_COUNT; lane=lane+1) begin
                registers[lane][dst]     <= registers[lane][src0] * registers[lane][src1];
            end
        end
        8:
        begin
            integer lane;
            for (lane=0; lane < LANE_COUNT; lane=lane+1) begin
                registers[lane][dst]     <= registers[lane][src0] / registers[lane][src1];
            end
        end
        9:
        begin
            integer lane;
            for (lane=0; lane < LANE_COUNT; lane=lane+1) begin
                registers[lane][dst]     <= 8'b00000000     | registers[lane][src1];
            end
        end
        10:
        begin
            integer lane;
            for (lane=0; lane < LANE_COUNT; lane=lane+1) begin
                registers[lane][dst1]   <= registers[lane][src0] | 8'b00000000;
            end
        end
        11:
        begin
            integer lane;
            for (lane=0; lane < LANE_COUNT; lane=lane+1) begin
                registers[lane][dst1]   <=           imm   | (src1 << 3);
            end
        end
        12:
        begin
            integer lane;
            for (lane=0; lane < LANE_COUNT; lane=lane+1) begin
                registers[lane][dst1]   <= registers[lane][src1] << shift_imm;
            end
        end
        13:
        begin
            integer lane;
            for (lane=0; lane < LANE_COUNT; lane=lane+1) begin
                registers[lane][dst1]   <= registers[lane][src1] >> shift_imm;
            end
        end

        16:
            if (registers[lane][src1]| != 0) begin
                IP = registers[lane][src0] << (lane*8) |;
                stall = 1'b1;
            end
        17:
            if (registers[lane][src1]| == 0) begin
                IP = registers[lane][src0] << (lane*8) |;
                stall = 1'b1;
            end
        18:
            begin
            IP = registers[lane][src0] << (lane*8) |;
            stall = 1'b1;
            end
        19:
            if (registers[lane][src1]| < 0) begin
                IP = registers[lane][src0] << (lane*8) |;
                stall = 1'b1;
            end
        20:
            if (registers[lane][src1]| > 0) begin
                IP = registers[lane][src0] << (lane*8) | ;
                stall = 1'b1;
            end
        24:
        begin
            data_address[lane] = registers[lane][src0];
            data_dst = dst;
            data_read_enable = 1'b1;
        end
        25:
        begin
            data_address[lane] = registers[lane][src0];
            data_dst = dst;
            data_write_enable = 1'b1;
            data_in_data[lane] = registers[lane][dst];
        end
        26:
        begin
            data_address[lane] = registers[lane][src0];
            data_dst = dst;
            data_write_enable = 1'b1;
            data_in_data[lane] = 8'b00000000;
        end
        27:
        begin
            data_address[lane] = registers[lane][src0];
            data_dst = dst;
            data_write_enable = 1'b1;
            data_read_enable = 1'b1;
            data_in_data[lane] = registers[lane][dst];
        end

        31:begin
            src1 <= arg;
        end
        default: $display("unknown opcode %b", opcode);
    endcase
end

endmodule
