// The memories of cpu_16_16_16_16 (docs/cpu_16_16_16_16.md section 5).
//
// They are separate from memory.v for the same reason gpu16_gmem.v and
// gpu16_lds.v are: they are a different shape, and memory.v's two arrays are
// pinned cycle for cycle by nine cross-check tests that have nothing to do
// with this core.
//
// Both are asynchronous read, which is the choice memory.v's header argues
// for the small arrays and against the large ones.  These are not small -
// 64 KiB each - so a board that builds this core at full size wants the
// registered-read `block_memory` shape instead and a fetch that presents the
// address a cycle early, exactly as gpu16.v does.  What is here is the form
// that keeps the core a one-cycle machine in simulation, and the module
// parameters are how a board shrinks it; see docs/cpu_16_16_16_16.md 5.
//
// There is no `initial` block in either: an array is filled by the loader in
// simulation and by the bitstream on hardware, and a memory is the one kind
// of state that legitimately has no reset.

// Instruction memory: one asynchronous read port for the fetch, and a loader
// that writes one 16 bit word per cycle while the CPU is held in reset.
//
// Unlike memory.v's `program_memory` there is no second port: this core has
// no successor to cpu16's ld_p/st_p, so nothing but the loader ever writes
// the instruction space (docs/cpu_16_16_16_16.md section 11).
module program_memory_16 #(
    parameter ADDR_WIDTH = 15,              // word address bits
    parameter RAM_DEPTH = 1 << ADDR_WIDTH
) (
    input clk,

    input enable,
    input [ADDR_WIDTH-1:0] address,
    output [15:0] out_data,

    input load_enable,
    input [ADDR_WIDTH-1:0] load_address,
    input [15:0] load_data
);

reg [15:0] mem[0:RAM_DEPTH-1];

always @(posedge clk) begin
    if (load_enable) begin
        mem[load_address] <= load_data;
    end
end

// A word that was never loaded reads as x, which matches no opcode class and
// is therefore reported as an unknown opcode.  That is how a program that
// runs off its own end is caught; see docs/cpu_16_16_16_16.md section 2.
assign out_data = !enable ? 16'b0 : mem[address];

endmodule

// Data memory: 16 bit words with two byte enables, which is what makes both
// the halfword and the byte accesses of section 3.3 one port rather than two
// arrays.  The address here is a *word* address - the core divides by two -
// and byte_enable[0] is the low byte, at the even byte address, because the
// machine is little endian.
//
// Reads are write first, like memory.v's: a read of the word being written
// in the same cycle returns the merged value.  Nothing in this core relies on
// that (there is no read-modify-write instruction), but leaving it undefined
// would be a difference between simulation and synthesis for no gain.
module byte_memory_16 #(
    parameter ADDR_WIDTH = 16,                      // byte address bits
    parameter RAM_DEPTH = 1 << (ADDR_WIDTH - 1)     // in 16 bit words
) (
    input clk,

    input enable,
    input write_enable,
    input [1:0] byte_enable,
    input [ADDR_WIDTH-2:0] address,                 // word address
    input [15:0] in_data,
    output [15:0] out_data
);

reg [15:0] mem[0:RAM_DEPTH-1];

wire write = enable & write_enable;

// The byte enables applied: a disabled lane keeps what the array holds.
wire [15:0] merged = {byte_enable[1] ? in_data[15:8] : mem[address][15:8],
                      byte_enable[0] ? in_data[7:0]  : mem[address][7:0]};

always @(posedge clk) begin
    if (write) begin
        mem[address] <= merged;
    end
end

assign out_data = !enable ? 16'b0
                : write   ? merged
                          : mem[address];

endmodule
