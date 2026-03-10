`include "memory.v"

module main(
    input clk
);

reg [7:0] IP;
wire write_ip;

always @(posedge clk) begin
    if (~write_ip) begin
        IP = IP + 1;
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
assign Inst = program_out_data;

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
    if (opcode == 0) begin
        registers[arg] <= registers[arg] & registers[0];
    end
    else if (opcode == 1) begin
        registers[arg] <= registers[arg] | registers[0];
    end
    else if (opcode == 2) begin
        registers[arg] <= ~registers[arg];
    end
    else if (opcode == 3) begin
        registers[arg] <= registers[arg] ^ registers[0];
    end
    else if (opcode == 4) begin
        registers[arg] <= registers[arg] + registers[0];
    end
    else if (opcode == 5) begin
        registers[arg] <= registers[arg] - registers[0];
    end
    else if (opcode == 6) begin
        registers[arg] <= -registers[arg];
    end
    else if (opcode == 7) begin
        registers[arg] <= registers[arg] * registers[0];
    end
    else if (opcode == 8) begin
        registers[arg] <= registers[arg] / registers[0];
    end
    else if (opcode == 9) begin
        registers[arg] <= registers[0];
    end
    else if (opcode == 10) begin
        registers[0] <= registers[arg];
    end
    else if (opcode == 11) begin
        registers[0] <= arg;
    end
    else if (opcode == 12) begin
        registers[0] <= registers[0] << arg;
    end
    else if (opcode == 13) begin
        registers[0] <= registers[0] >> arg;
    end
    else if (opcode == 16) begin
        if (registers[0] != 0) begin
            IP = registers[arg];
        end
    end
    else if (opcode == 17) begin
        if (registers[0] == 0) begin
            IP = registers[arg];
        end
    end
    else if (opcode == 18) begin
        IP = registers[arg];
    end
    else if (opcode == 19) begin
        if (registers[0] < 0) begin
            IP = registers[arg];
        end
    end
    else if (opcode == 20) begin
        if (registers[0] > 0) begin
            IP = registers[arg];
        end
    end
    else begin
        $display("unknown opcode %b", opcode);
    end
end

assign write_ip = opcode == 16 && registers[0] != 0 ||
    opcode == 17 && registers[0] == 0 ||
    opcode == 18 ||
    opcode == 19 && registers[0] < 0 ||
    opcode == 20 && registers[0] > 0;

endmodule
