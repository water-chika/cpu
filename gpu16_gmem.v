// gpu16's global memory, as wide as docs/gpu_isa.md section 3.1 says it is.
//
// "The global port moves 64 B per cycle, aligned."  That sentence is the
// whole module: the array underneath is still 32 bit words, so a `.data32`
// file loads into it with one $readmemh exactly as it did when the only
// customer was `s_ld_g`, but the port on the outside is one aligned 64 byte
// **block** - sixteen words - per cycle.  A wave-wide access that touches one
// block therefore finishes in one cycle and one that touches sixteen takes
// sixteen, which is section 3.1's transaction rule expressed as hardware
// rather than as a comment.
//
// Reads are asynchronous, as in `memory.v` and for the same reason: the
// address is produced by one clock edge and the data consumed by the next, so
// it has a whole cycle to settle.  Unlike `memory.v` there is no write-first
// bypass, because the one customer - `gpu16.v`'s memory unit - never reads
// and writes in the same cycle: a store spends its cycles scattering and a
// load spends its cycles gathering, and an instruction does only one of the
// two.
//
// Writes are byte enabled.  `v_st_g` writes one byte per lane, so a block
// write that could only be done a whole word at a time would have to read,
// modify and write back, and the read half of that is a port cycle section
// 3.1 does not budget for.
module gpu16_gmem #(
    // How many 32 bit words this instance implements.  The architectural
    // space is 24 address bits (section 3, 16 MiB); a simulation wants far
    // less.  Must be at least 4, since one block is sixteen words.
    parameter WORD_INDEX_WIDTH = 10
) (
    input clk,

    // Which aligned 64 byte block: the effective address with its low six
    // bits dropped.
    input [WORD_INDEX_WIDTH-5:0] block_index,

    input write_enable,
    // One bit per byte of the block, little-endian: bit b enables byte b,
    // which is bit 8b of in_block and lives in word b >> 2.
    input [63:0] byte_enable,
    input [511:0] in_block,

    output [511:0] out_block
);

localparam WORDS = 1 << WORD_INDEX_WIDTH;

reg [31:0] mem[0:WORDS-1];

// The word index of the first word of the block.  The low four bits are zero
// by construction, which is what lets the per word address below be an OR
// rather than an add.
wire [WORD_INDEX_WIDTH-1:0] base = {block_index, 4'b0};

genvar w;
generate
    for (w = 0; w < 16; w = w + 1) begin : word
        localparam [WORD_INDEX_WIDTH-1:0] OFFSET = w;
        assign out_block[32*w+:32] = mem[base | OFFSET];
    end
endgenerate

integer i;
integer b;

always @(posedge clk) begin
    if (write_enable) begin
        for (i = 0; i < 16; i = i + 1) begin
            for (b = 0; b < 4; b = b + 1) begin
                if (byte_enable[4*i+b]) begin
                    mem[base | i[3:0]][8*b+:8] <= in_block[32*i+8*b+:8];
                end
            end
        end
    end
end

endmodule
