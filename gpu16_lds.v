// gpu16's LDS, banked the way docs/gpu_isa.md section 3.2 says it is.
//
// "8 KiB, shared by the 4 waves of a workgroup, organised as 16 banks of 4
// bytes; bank = (address >> 2) & 15."  The banks are the module: sixteen
// independently addressed 32 bit memories, each with its own row input, so
// one cycle can serve sixteen lanes reading sixteen *different* rows as long
// as they are in sixteen different banks.  That is the whole difference
// between this and `gpu16_gmem.v`, which serves sixteen lanes in one cycle
// only when they share one 64 byte block, and it is why section 3.2 can
// promise a conflict-free strided read at all.
//
// The address decode falls out of the sentence above.  A 13 bit byte address
// (8 KiB) splits as
//
//   addr[12:6]  row, 0..127
//   addr[5:2]   bank, 0..15
//   addr[1:0]   byte within the bank word
//
// so the flat word index is `{row, bank}` - which is just `addr >> 2` - and
// the array underneath can still be one plain `reg [31:0] mem[]` that a
// `$readmemh` fills in address order.  The bank is the *low* part of the word
// index rather than the high part, which is exactly why consecutive words go
// to consecutive banks and why the stride argument in section 3.2 works out
// as `(m * S/4 + c) & 15`.
//
// Reads are asynchronous and writes are byte enabled, for the same two
// reasons as in `gpu16_gmem.v`: the address is produced by one clock edge and
// consumed by the next, and `v_st_l` writes one byte per lane, which a
// word-only write port could only do by reading first.
//
// This module does not know what a conflict is.  Resolving sixteen lane
// addresses into a sequence of conflict-free cycles is the memory unit's job
// in `gpu16.v`; what arrives here is always one row per bank, already legal.
module gpu16_lds #(
    // Rows of sixteen banks.  128 x 16 x 4 B = 8 KiB, section 3.2's size.
    parameter ROWS = 128,
    parameter ROW_WIDTH = 7
) (
    input clk,

    // Which row each bank reads or writes this cycle, sixteen ROW_WIDTH bit
    // fields, bank 0 at the bottom.  A bank that is not taking part still has
    // to be given something; zero is as good as anything, since its write
    // enable is low and nothing looks at its output.
    input [16*ROW_WIDTH-1:0] bank_row,

    // Bit b writes bank b.
    input [15:0] bank_write,
    // One bit per byte, bit 4b+n being byte n of bank b.
    input [63:0] byte_enable,
    // Sixteen 32 bit words, bank 0 at the bottom.
    input [511:0] in_data,

    output [511:0] out_data
);

reg [31:0] mem[0:16*ROWS-1];

integer b;
integer n;

genvar g;
generate
    for (g = 0; g < 16; g = g + 1) begin : bank
        localparam [3:0] INDEX = g;
        // {row, bank}: the row picked for this bank, with the bank number in
        // the low four bits.
        wire [ROW_WIDTH+3:0] word = {bank_row[ROW_WIDTH*g+:ROW_WIDTH], INDEX};
        assign out_data[32*g+:32] = mem[word];
    end
endgenerate

always @(posedge clk) begin
    for (b = 0; b < 16; b = b + 1) begin
        if (bank_write[b]) begin
            for (n = 0; n < 4; n = n + 1) begin
                if (byte_enable[4*b+n]) begin
                    mem[{bank_row[ROW_WIDTH*b+:ROW_WIDTH], b[3:0]}][8*n+:8]
                        <= in_data[32*b+8*n+:8];
                end
            end
        end
    end
end

endmodule
