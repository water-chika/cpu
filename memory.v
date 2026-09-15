// The memories.
//
// Both of these are written so that a synthesis tool will accept them: every
// piece of state is written with a non blocking assignment inside a single
// `always @(posedge clk)`, there are no delays anywhere, and there is no
// `initial` block pretending to be a reset.  A memory array is the one kind
// of state that legitimately has no reset - it is filled by $readmemh in
// simulation and by the bitstream or the mask on real hardware - so none of
// the arrays below are reset either.
//
// Reads are asynchronous: `out_data` is a combinational function of the
// address.  That is deliberate, and it is what keeps the CPU's timing exactly
// what it was when the read port was a register clocked on the same edge that
// consumed it.  A read is issued in one cycle and consumed on the next clock
// edge, so the address has a whole cycle to propagate.  On an FPGA this maps
// to distributed RAM rather than to a block RAM.
//
// Reads are write first: a read of the address being written in the same
// cycle returns the value being written, which is what cpu16's read modify
// write opcode relies on.

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
   output [DATA_WIDTH-1:0] out_data
);

reg [DATA_WIDTH-1:0] mem[0:RAM_DEPTH-1];

wire write = enable & write_enable;

always @(posedge clk) begin
    if (write) begin
        mem[address] <= in_data;
    end
end

assign out_data = !enable ? {DATA_WIDTH{1'b0}}
                : write   ? in_data
                          : mem[address];

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
// stored here takes effect the next time it is fetched.  That bypass is the
// explicit mux below; it used to be an accident of one blocking assignment
// happening before another inside the same always block.
module program_memory #(
   parameter ADDR_WIDTH = 8,
   parameter RAM_DEPTH = 1 << ADDR_WIDTH
) (
   input clk,

   input a_enable,
   input [ADDR_WIDTH-1:0] a_address,
   output [15:0] a_out_data,

   input b_enable,
   input b_write_enable,
   input b_half, // 0: low byte of the word, 1: high byte
   input [ADDR_WIDTH-1:0] b_address,
   input [7:0] b_in_data,
   output [7:0] b_out_data
);

reg [15:0] mem[0:RAM_DEPTH-1];

wire b_write = b_enable & b_write_enable;

always @(posedge clk) begin
    if (b_write) begin
        if (b_half) begin
            mem[b_address][15:8] <= b_in_data;
        end
        else begin
            mem[b_address][7:0] <= b_in_data;
        end
    end
end

assign b_out_data = !b_enable ? 8'b0
                  : b_write   ? b_in_data
                  : b_half    ? mem[b_address][15:8]
                              : mem[b_address][7:0];

// The port A bypass: a byte being written on port B this cycle is merged into
// the word port A is fetching, so a store to the instruction being fetched is
// seen immediately, exactly as it was before.
wire [15:0] a_word = mem[a_address];
wire [15:0] a_bypassed = b_half ? {b_in_data, a_word[7:0]}
                                : {a_word[15:8], b_in_data};

assign a_out_data = !a_enable ? 16'b0
                  : (b_write && b_address == a_address) ? a_bypassed
                                                        : a_word;

endmodule
