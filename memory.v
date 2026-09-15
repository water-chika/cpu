module memory #(
   parameter DATA_WIDTH = 8,
   parameter ADDR_WIDTH = 8,
   parameter RAM_DEPTH = 1 << ADDR_WIDTH
) (
   input clk,
   input write_enable,
   input enable,
   input [ADDR_WIDTH-1:0] address,
   input [DATA_WIDTH-1:0] in_data,
   output reg [DATA_WIDTH-1:0] out_data
);

reg [DATA_WIDTH-1:0] mem[0:RAM_DEPTH-1];

always @(posedge clk) begin
    if (enable) begin
        if (write_enable) begin
            mem[address] = in_data;
        end
        out_data = mem[address];
    end
end

initial begin
    //$monitor("write_enable=%b, read_enable=%b, address=%8b, in_data=%8b, out_data=%8b",
    //    write_enable, read_enable, address, in_data, out_data);
end

endmodule

// Program memory with two ports.
//
// Port A is the instruction fetch: one 16 bit word per cycle, read only.
// Port B is what ld_p and st_p use: one byte per cycle, read or write,
// selecting the low or the high half of a word with b_half.  A second port is
// exactly what those two instructions need - without it a program cannot
// touch its own instruction memory while it is still being fetched from.
//
// A write on port B is visible to port A in the same cycle, so an instruction
// stored here takes effect the next time it is fetched.
module program_memory #(
   parameter ADDR_WIDTH = 8,
   parameter RAM_DEPTH = 1 << ADDR_WIDTH
) (
   input clk,

   input a_enable,
   input [ADDR_WIDTH-1:0] a_address,
   output reg [15:0] a_out_data,

   input b_enable,
   input b_write_enable,
   input b_half, // 0: low byte of the word, 1: high byte
   input [ADDR_WIDTH-1:0] b_address,
   input [7:0] b_in_data,
   output reg [7:0] b_out_data
);

reg [15:0] mem[0:RAM_DEPTH-1];

always @(posedge clk) begin
    if (b_enable) begin
        if (b_write_enable) begin
            if (b_half) begin
                mem[b_address][15:8] = b_in_data;
            end
            else begin
                mem[b_address][7:0] = b_in_data;
            end
        end
        b_out_data = b_half ? mem[b_address][15:8] : mem[b_address][7:0];
    end
    if (a_enable) begin
        a_out_data = mem[a_address];
    end
end

endmodule
