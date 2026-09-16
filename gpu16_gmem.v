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
// Reads are **synchronous**, which is the whole point of the module being a
// separate one: a block RAM has a registered read port, so an array read
// combinationally cannot be a BRAM and a synthesis tool builds LUTRAM or
// registers instead (docs/fpga_bringup.md 2.2b).  `out_block` therefore
// belongs to the `block_index` presented on the *previous* clock edge, and
// `gpu16.v`'s memory unit pipelines against that: it presents one block
// address per cycle and writes the data of the block it asked for one cycle
// later, so an access still costs one port cycle per distinct block and
// section 3.1's transaction rule is unchanged.  What it costs is one extra
// cycle at the end of a load, to let the last block's data land.
//
// Read-first, and no write-first bypass: the write is scheduled before the
// read in the same clocked block, so a read of a block being written returns
// the value from before the write.  A bypass would be a combinational path
// from the write data to the read data, which is precisely what a BRAM
// cannot do.  Nothing needs one - the one customer never reads and writes in
// the same cycle, because a store spends its cycles scattering and a load
// spends its cycles gathering, and an instruction does only one of the two.
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

reg [511:0] out_block_r;

integer i;
integer b;
integer r;

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
    // After the write, so this is the read-first template: sixteen words out
    // of one aligned block, registered.
    for (r = 0; r < 16; r = r + 1) begin
        out_block_r[32*r+:32] <= mem[base | r[3:0]];
    end
end

assign out_block = out_block_r;

endmodule
