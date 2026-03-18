`include "memory.v"

module main(
    input clk
);

reg [7:0] IP;
reg stall;
reg [7:0] stall_counter;

initial begin
    stall = 1'b1;
    stall_counter = 3;
end

always @(posedge clk) begin
    if (stall == 1'b1) begin
        if (stall_counter == 0) begin
            stall = 1'b0;
        end
        else begin
            stall_counter = stall_counter-1;
        end
    end
    else begin
        stall = 1'b1;
        stall_counter = 1;
    end
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
.read_enable(program_read_enable),
.address(program_address),
.in_data(program_in_data),
.out_data(program_out_data)
);

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
    IP = IP;

    if (~stall) begin
        IP = IP + 1;
    end

    case (opcode)
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
            end
        17:
            if (registers[0] == 0) begin
                IP = registers[arg];
            end
        18: IP = registers[arg];
        19:
            if (registers[0] < 0) begin
                IP = registers[arg];
            end
        20:
            if (registers[0] > 0) begin
                IP = registers[arg];
            end
        default: $display("unknown opcode %b", opcode);
    endcase
end

endmodule
