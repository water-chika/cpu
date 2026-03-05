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

reg [7:0] RAM[256];
wire [7:0] Inst;

assign Inst = RAM[IP];

reg [7:0] registers[8];

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

wire [7:0] src0_value;
wire [7:0] src1_value;

assign src0_value = registers[dst];
assign src1_value = registers[src];

always @(posedge clk) begin
    if (opcode == 0) begin
        registers[dst] <= imm;
    end
    else if (opcode == 1) begin
        registers[dst] <= src0_value + src1_value;
    end
    else if (opcode == 2) begin
        registers[dst] <= src0_value - src1_value;
    end
    else begin
        if (opcode2 == 0) begin
            IP <= src1_value;
        end
        else if (opcode2 == 1) begin
        end
        else if (opcode2 == 2) begin
        end
        else begin
        end
    end
end

assign write_ip = opcode == 3 && opcode2 == 0;

endmodule
