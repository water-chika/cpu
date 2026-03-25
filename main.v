`include "memory.v"

module main(
    input clk
);

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
wire [7:0] program_in_data;
wire [7:0] program_out_data;

memory program(
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

wire [7:0] Inst;

assign program_address = IP;
assign program_read_enable = 1'b1;
assign program_write_enable = 1'b0;
assign program_in_data = 8'b00000000;
assign Inst = stall ? 8'b00000000 : program_out_data;

reg [7:0] registers[7:0];

initial begin:INIT_REGS
    integer i;
    for (i = 0; i < 8; i=i+1) begin
        registers[i] <= 0;
    end
end

wire [4:0] opcode;
wire [2:0] arg;

assign opcode = Inst[7:3];
assign arg = Inst[2:0];

always @(posedge clk) begin

    // delay to wait memory operation
    #1 if (data_write_enable) begin
        data_write_enable = 1'b0;
    end
    if (data_read_enable) begin
        registers[0] = data_out_data;
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
        0: registers[arg] <= registers[arg] & registers[0];
        1: registers[arg] <= registers[arg] | registers[0];
        2: registers[arg] <= ~registers[arg];
        3: registers[arg] <= registers[arg] ^ registers[0];
        4: registers[arg] <= registers[arg] + registers[0];
        5: registers[arg] <= registers[arg] - registers[0];
        6: registers[arg] <= -registers[arg];
        7: registers[arg] <= registers[arg] * registers[0];
        8: registers[arg] <= registers[arg] / registers[0];
        9: registers[arg] <= registers[0];
        10: registers[0] <= registers[arg];
        11: registers[0] <= arg;
        12: registers[0] <= registers[0] << arg;
        13: registers[0] <= registers[0] >> arg;
        16:
            if (registers[0] != 0) begin
                IP = registers[arg];
                stall = 1'b1;
            end
        17:
            if (registers[0] == 0) begin
                IP = registers[arg];
                stall = 1'b1;
            end
        18:
            begin
            IP = registers[arg];
            stall = 1'b1;
            end
        19:
            if (registers[0] < 0) begin
                IP = registers[arg];
                stall = 1'b1;
            end
        20:
            if (registers[0] > 0) begin
                IP = registers[arg];
                stall = 1'b1;
            end
        24:
        begin
            data_address = registers[arg];
            data_read_enable = 1'b1;
        end
        25:
        begin
            data_address = registers[arg];
            data_write_enable = 1'b1;
            data_in_data = registers[0];
        end
        26:
        begin
            data_address = registers[arg];
            data_write_enable = 1'b1;
            data_in_data = 8'b00000000;
        end
        27:
        begin
            data_address = registers[arg];
            data_write_enable = 1'b1;
            data_read_enable = 1'b1;
            data_in_data = registers[0];
        end
        default: $display("unknown opcode %b", opcode);
    endcase
end

endmodule
