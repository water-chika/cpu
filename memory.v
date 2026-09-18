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
//
// `memory`, `program_memory` and `program_memory8` below are all
// asynchronous-read and stay that way.  That is a deliberate choice and not an
// oversight: they are the two CPUs' memories, 256 entries each, which is
// 2 Kbit and 4 Kbit - far
// below the 18 Kbit granularity of a block RAM, so distributed RAM is the
// right primitive for them anyway.  Converting them would also change cpu8's
// and cpu16's timing, which the nine RTL-vs-C++ cross-check tests pin down
// cycle for cycle.  `block_memory` at the bottom of this file is the
// registered-read form, and it is what the *large* arrays use.

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
// There is also a loader: `load_enable` / `load_address` / `load_data` write
// one whole 16 bit word per cycle and take priority over port B.  This is the
// port a program arrives through on a device, and it is deliberately not a
// third write port - it is a mux in front of the one port B already had, so
// it costs an address and a data multiplexer and no extra memory port.  The
// host holds the CPU in reset while it loads, so the conflict the priority
// resolves never happens in practice; the priority exists so the behaviour is
// defined rather than hoped for.
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
   output [7:0] b_out_data,

   // The loader.  One 16 bit word per cycle, write only, priority over B.
   input load_enable,
   input [ADDR_WIDTH-1:0] load_address,
   input [15:0] load_data
);

reg [15:0] mem[0:RAM_DEPTH-1];

wire b_write = b_enable & b_write_enable;

always @(posedge clk) begin
    if (load_enable) begin
        mem[load_address] <= load_data;
    end
    else if (b_write) begin
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

// Program memory with two ports, 8 bits wide: cpu8's.
//
// The same shape as `program_memory` above and for the same reason - port A
// is the instruction fetch and port B is what ld_p and st_p run on - with one
// simplification that falls out of the width.  cpu8's instruction word is 8
// bits and so is its register, so a program word is exactly one register and
// there is no half to select: `b_half` has no counterpart here, and cpu8's
// ld_p and st_p take one operand where cpu16's take a half as well.
//
// Everything else is identical, including the two things that are easy to get
// wrong: the loader is a mux in front of port B rather than a third port and
// takes priority over it, and a byte written on port B is bypassed into port
// A in the same cycle, so an instruction a program stores over itself takes
// effect the next time it is fetched.
module program_memory8 #(
   parameter ADDR_WIDTH = 8,
   parameter RAM_DEPTH = 1 << ADDR_WIDTH
) (
   input clk,

   input a_enable,
   input [ADDR_WIDTH-1:0] a_address,
   output [7:0] a_out_data,

   input b_enable,
   input b_write_enable,
   input [ADDR_WIDTH-1:0] b_address,
   input [7:0] b_in_data,
   output [7:0] b_out_data,

   // The loader.  One 8 bit word per cycle, write only, priority over B.
   input load_enable,
   input [ADDR_WIDTH-1:0] load_address,
   input [7:0] load_data
);

reg [7:0] mem[0:RAM_DEPTH-1];

wire b_write = b_enable & b_write_enable;

always @(posedge clk) begin
    if (load_enable) begin
        mem[load_address] <= load_data;
    end
    else if (b_write) begin
        mem[b_address] <= b_in_data;
    end
end

assign b_out_data = !b_enable ? 8'b0
                  : b_write   ? b_in_data
                              : mem[b_address];

assign a_out_data = !a_enable ? 8'b0
                  : (b_write && b_address == a_address) ? b_in_data
                                                        : mem[a_address];

endmodule

// A registered-read memory: the shape a block RAM actually has.
//
// `memory` above reads combinationally, which is fine for a 2 Kbit array and
// wrong for a large one - Xilinx block RAM has a registered read port, so an
// array read combinationally cannot be a BRAM and the tool builds LUTRAM
// instead, silently, or falls back to registers where the port count defeats
// even that.  With `PROGRAM_ADDR_WIDTH = 12` the gpu16 instruction memory is
// 131 Kbit *per wave* and there are four waves to a compute unit, so that
// difference is most of a small Artix-7.  See docs/fpga_bringup.md 2.2(b).
//
// The template below is the read-first one: the write is scheduled before the
// read in the same clocked block, so a read of the address being written
// returns the value from before the write.  Both Xilinx and Altera recognise
// it.  There is no bypass mux, because a bypass is a combinational path from
// the write data to the read data and that is exactly what a BRAM cannot do.
//
// The cost is that `out_data` belongs to the address presented on the
// *previous* clock edge.  A user therefore has to present the address one
// cycle early; gpu16.v's fetch does that by reading with the value the PC is
// about to take rather than with the PC.
module block_memory #(
   parameter DATA_WIDTH = 32,
   parameter ADDR_WIDTH = 12,
   parameter RAM_DEPTH = 1 << ADDR_WIDTH
) (
   input clk,
   input write_enable,
   input [ADDR_WIDTH-1:0] address,
   input [DATA_WIDTH-1:0] in_data,
   output [DATA_WIDTH-1:0] out_data
);

reg [DATA_WIDTH-1:0] mem[0:RAM_DEPTH-1];
reg [DATA_WIDTH-1:0] out_data_r;

always @(posedge clk) begin
    if (write_enable) begin
        mem[address] <= in_data;
    end
    out_data_r <= mem[address];
end

assign out_data = out_data_r;

endmodule
